# frozen_string_literal: true

module SmartRouting
  # Детерминированная симуляция поведения провайдера.
  #
  # Различаем два принципиально разных события:
  #
  #   1. Провайдер не принял заявку (`handoff` вернул :declined/:timeout).
  #      Это ретраибельный отказ — роутер исключает провайдера и идёт
  #      к следующему кандидату, а если их не осталось — к self-provider.
  #
  #   2. Провайдер принял заявку и обработал её (`outcome`).
  #      Результат approved / rejected / expired — терминальный исход
  #      операции, маршрут он уже не меняет.
  #
  # Искусственные отказы первого рода по умолчанию выключены
  # (simulation.declines.enabled: false), чтобы сдаваемый прогон был
  # полностью воспроизводимым. Механика каскада от этого не исчезает:
  # она включается демо-профилем и покрыта тестами.
  #
  # Случайность детерминирована: seed конфига + operation_id + имя провайдера.
  # Один и тот же вход всегда даёт один и тот же выход.
  class Simulator
    EXPIRED_LATENCY_RANGE = (300..900).freeze

    def initialize(config)
      @config = config
      @settings = config.simulation || {}
      @seed = (@settings['seed'] || 0).to_i
    end

    def declines_enabled?
      @settings.dig('declines', 'enabled') == true
    end

    # Принял ли провайдер заявку в работу.
    # @return [Symbol] :accepted | :declined | :timeout
    def handoff(operation, provider)
      return :accepted unless declines_enabled?

      roll = random_for(operation, provider, 'handoff').rand
      return :accepted if roll >= decline_probability(provider)

      timeout_share = (@settings.dig('declines', 'timeout_share') || 0.4).to_f
      random_for(operation, provider, 'handoff_kind').rand < timeout_share ? :timeout : :declined
    end

    # Терминальный исход уже принятой заявки.
    # @return [Array(String, Integer)] результат и задержка в секундах
    def outcome(operation, provider, conversion: nil)
      success_rate = (conversion || provider.conversion_24h).to_f
      roll = random_for(operation, provider, 'outcome').rand

      if roll < success_rate
        ['approved', latency(operation, provider)]
      elsif expired?(operation, provider)
        ['expired', expired_latency(operation, provider)]
      else
        ['rejected', latency(operation, provider)]
      end
    end

    private

    def decline_probability(provider)
      configured = @settings.dig('declines', 'rate')
      return configured.to_f if configured

      # По умолчанию отказ в приёме — небольшая часть общего недобора конверсии.
      share = (@settings.dig('declines', 'share_of_failures') || 0.25).to_f
      (1.0 - provider.conversion_24h) * share
    end

    def expired?(operation, provider)
      share = (@settings['expired_share_of_failures'] || 0.35).to_f
      random_for(operation, provider, 'expired').rand < share
    end

    def latency(operation, provider)
      jitter_pct = (@settings['latency_jitter_pct'] || 30).to_f / 100.0
      base = provider.avg_latency_sec
      factor = 1.0 + ((random_for(operation, provider, 'latency').rand * 2) - 1) * jitter_pct
      [(base * factor).round, 1].max
    end

    def expired_latency(operation, provider)
      span = EXPIRED_LATENCY_RANGE
      span.first + (random_for(operation, provider, 'expired_latency').rand * (span.last - span.first)).round
    end

    # Стабильный между запусками и платформами источник случайности:
    # String#hash в Ruby рандомизирован на старте процесса, поэтому SHA-256.
    def random_for(operation, provider, salt)
      digest = Digest::SHA256.hexdigest("#{@seed}|#{operation.id}|#{provider.name}|#{salt}")
      Random.new(digest[0, 15].to_i(16))
    end
  end
end
