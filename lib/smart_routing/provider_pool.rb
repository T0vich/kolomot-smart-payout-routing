# frozen_string_literal: true

module SmartRouting
  # Живое состояние всех провайдеров на протяжении прогона очереди.
  #
  # Отвечает за три вещи:
  #   1) модельное время (in-progress освобождается, когда операция завершилась);
  #   2) резервирование лимитов при выборе провайдера и их списание по факту;
  #   3) агрегаты долей count/volume, на которых работают soft-goals.
  class ProviderPool
    attr_reader :providers, :rate_limiter, :now, :config

    def initialize(providers, config:, warm_start: nil)
      @providers = providers
      @by_name = providers.to_h { |p| [p.name, p] }
      @config = config
      @rate_limiter = RateLimiter.new
      @in_flight = []
      @now = nil
      @total_count = 0
      @total_amount = 0.0
      apply_warm_start(warm_start) if warm_start
    end

    def [](name) = @by_name[name]

    # Провайдеры, участвующие в обычном роутинге (без self-provider).
    def routable
      providers.reject(&:fallback_role?).sort_by { |p| [p.priority, p.name] }
    end

    def fallback
      name = config.fallback_provider
      return nil if name.nil?

      @by_name[name] || providers.find(&:fallback_role?)
    end

    # Продвигаем модельное время: всё, что успело завершиться, освобождает слоты.
    def advance_clock(time)
      @now = time
      return if time.nil?

      @in_flight.reject! do |item|
        next false if item[:finish_at] > time

        settle(item)
        true
      end
    end

    # Провайдер принял заявку: занимаем слот и резервируем дневной лимит.
    def occupy(provider, operation, latency_sec, result)
      provider.in_progress_count += 1
      provider.in_progress_amount += operation.amount
      provider.daily_reserved_amount += operation.amount
      provider.available_requisites -= 1 if provider.available_requisites.positive?
      provider.routed_count += 1
      provider.routed_amount += operation.amount

      @total_count += 1
      @total_amount += operation.amount
      @rate_limiter.record(provider.name, operation.created_at || @now)

      finish_at = (operation.created_at || @now)
      finish_at = finish_at.nil? ? nil : finish_at + latency_sec
      item = { provider: provider, amount: operation.amount, result: result, finish_at: finish_at }
      finish_at.nil? ? settle(item) : @in_flight << item
    end

    # Досчитываем всё, что осталось «в полёте», после конца очереди.
    def drain!
      @in_flight.each { |item| settle(item) }
      @in_flight = []
    end

    # --- агрегаты для soft-goals ---

    def routed_total_count = @total_count
    def routed_total_amount = @total_amount

    def share(kind, provider_name)
      case kind
      when :count then Support::Numeric.safe_div(@by_name[provider_name]&.routed_count.to_i, @total_count)
      when :volume then Support::Numeric.safe_div(@by_name[provider_name]&.routed_amount.to_f, @total_amount)
      else raise ArgumentError, "неизвестный вид доли: #{kind}"
      end
    end

    def target_share(kind, provider)
      case kind
      when :count then provider.traffic_percentage / 100.0
      when :volume then provider.volume_share_pct / 100.0
      else raise ArgumentError, "неизвестный вид доли: #{kind}"
      end
    end

    # Суммарное отклонение фактических долей от целевых, если заявку отдать
    # кандидату `candidate`. Меньше — лучше; это и есть измеримая «цель по долям».
    def share_error_after(kind, candidate, amount)
      weighted = routable.select { |p| target_share(kind, p).positive? }
      return 0.0 if weighted.empty?

      total = kind == :count ? @total_count + 1 : @total_amount + amount
      return 0.0 if total.zero?

      weighted.sum do |p|
        actual = if kind == :count
                   (p.routed_count + (p.name == candidate.name ? 1 : 0)).to_f / total
                 else
                   (p.routed_amount + (p.name == candidate.name ? amount : 0.0)) / total
                 end
        (actual - target_share(kind, p)).abs
      end
    end

    def current_share_error(kind)
      weighted = routable.select { |p| target_share(kind, p).positive? }
      return 0.0 if weighted.empty?

      weighted.sum { |p| (share(kind, p.name) - target_share(kind, p)).abs }
    end

    def snapshot
      providers.map(&:snapshot)
    end

    private

    def settle(item)
      provider = item[:provider]
      provider.in_progress_count -= 1 if provider.in_progress_count.positive?
      provider.in_progress_amount -= item[:amount]
      provider.in_progress_amount = 0.0 if provider.in_progress_amount.negative?
      provider.daily_reserved_amount -= item[:amount]
      provider.daily_reserved_amount = 0.0 if provider.daily_reserved_amount.negative?
      provider.available_requisites += 1

      if item[:result] == 'approved'
        provider.daily_approved_amount += item[:amount]
        provider.approved_count += 1
      else
        provider.failed_count += 1
      end
    end

    # Прогрев счётчиков историческими долями: полезно, когда очередь
    # продолжает уже начатый день, а не стартует с нуля.
    def apply_warm_start(stats)
      stats.each do |name, data|
        provider = @by_name[name]
        next unless provider

        provider.routed_count += data['count'].to_i
        provider.routed_amount += data['amount'].to_f
        @total_count += data['count'].to_i
        @total_amount += data['amount'].to_f
      end
    end
  end
end
