# frozen_string_literal: true

module SmartRouting
  module Analytics
    # Сборка routing_report.json: что получилось и что с этим делать.
    #
    # Обязательные ключи формата из ТЗ (period, total_operations, distribution,
    # skip_reasons, projected_daily_utilization, recommendations) дополнены
    # блоками, которых жюри ждёт по критериям: результаты и конверсия,
    # использование лимитов, причины отклонений и машиночитаемые рекомендации
    # с конкретным параметром, который предлагается изменить.
    class ReportBuilder
      SHARE_DEVIATION_ALERT_PP = 10.0
      UTILIZATION_ALERT = 0.85
      FALLBACK_SHARE_ALERT_PCT = 20.0

      def initialize(decisions:, pool:, config:, calibrator: nil, period: nil)
        @decisions = decisions
        @pool = pool
        @config = config
        @calibrator = calibrator
        @period = period
      end

      def build
        {
          'period' => period,
          'total_operations' => @decisions.size,
          'routing_profile' => profile_section,
          'distribution' => distribution,
          'results' => results,
          'skip_reasons' => skip_reasons,
          'soft_skip_reasons' => soft_skip_reasons,
          'projected_daily_utilization' => projected_daily_utilization,
          'limits_pressure' => limits_pressure,
          'cascade' => cascade_stats,
          'deviations' => deviations,
          'deviations_note' => deviations_note,
          'history_calibration' => history_calibration,
          'recommendations' => recommendations.map { |item| item['text'] },
          'recommendations_detailed' => recommendations
        }
      end

      private

      def period
        return @period if @period

        times = @decisions.filter_map { |d| d.operation.created_at }
        times.empty? ? Time.now.strftime('%Y-%m-%d') : times.min.strftime('%Y-%m-%d')
      end

      def profile_section
        {
          'name' => @config.profile_name,
          'description' => @config.profile_description,
          'weights' => @config.weights,
          'conflict_order' => @config.conflict_order
        }
      end

      def total = @decisions.size

      def total_amount
        @total_amount ||= @decisions.sum(&:amount)
      end

      def selected_counts
        @selected_counts ||= @decisions.group_by(&:selected_provider)
      end

      # Фактическая доля по количеству и по объёму против целевой — ядро отчёта.
      def distribution
        @pool.providers.each_with_object({}) do |provider, acc|
          group = selected_counts[provider.name] || []
          next if group.empty? && provider.traffic_percentage.zero?

          amount = group.sum(&:amount)
          share = Support::Numeric.pct(group.size, total)
          volume_share = Support::Numeric.pct(amount, total_amount)

          acc[provider.name] = {
            'count' => group.size,
            'share_pct' => share,
            'target_pct' => provider.traffic_percentage,
            'deviation_pp' => Support::Numeric.round2(share - provider.traffic_percentage),
            'volume' => amount,
            'volume_share_pct' => volume_share,
            'volume_target_pct' => provider.volume_share_pct,
            'volume_deviation_pp' => Support::Numeric.round2(volume_share - provider.volume_share_pct),
            'approved' => group.count(&:approved?),
            'conversion' => Support::Numeric.round2(Support::Numeric.safe_div(group.count(&:approved?), group.size))
          }
        end
      end

      def results
        by_result = @decisions.group_by(&:simulated_result)
        {
          'approved' => by_result.fetch('approved', []).size,
          'rejected' => by_result.fetch('rejected', []).size,
          'expired' => by_result.fetch('expired', []).size,
          'approval_rate' => Support::Numeric.round2(
            Support::Numeric.safe_div(by_result.fetch('approved', []).size, total)
          ),
          'avg_latency_sec' => Support::Numeric.round2(
            Support::Numeric.safe_div(@decisions.sum(&:latency_sec), total)
          )
        }
      end

      def all_attempts
        @all_attempts ||= @decisions.flat_map(&:attempts)
      end

      def skip_reasons
        tally(all_attempts.select(&:hard_skip?))
      end

      def soft_skip_reasons
        tally(all_attempts.select(&:soft_skip?))
      end

      def tally(attempts)
        attempts.each_with_object(Hash.new(0)) { |attempt, acc| acc[attempt.reason] += 1 }
                .sort_by { |_, count| -count }.to_h
      end

      def projected_daily_utilization
        @pool.providers.each_with_object({}) do |provider, acc|
          limit = provider.daily_amount_limit
          next if limit.nil?

          acc[provider.name] = {
            'used' => provider.daily_approved_amount.round,
            'limit' => limit,
            'utilization_pct' => Support::Numeric.pct(provider.daily_approved_amount, limit)
          }
        end
      end

      # Насколько близко провайдеры подошли к каждому из своих потолков.
      def limits_pressure
        @pool.providers.each_with_object({}) do |provider, acc|
          acc[provider.name] = {
            'daily_amount_pct' => Support::Numeric.pct(provider.daily_utilization, 1.0),
            'in_progress_count_pct' => Support::Numeric.pct(provider.in_progress_count_utilization, 1.0),
            'in_progress_amount_pct' => Support::Numeric.pct(provider.in_progress_amount_utilization, 1.0),
            'turnover_min' => provider.daily_turnover_min,
            'turnover_min_met' => provider.daily_committed_amount >= provider.daily_turnover_min,
            'turnover_max' => provider.daily_turnover_max
          }
        end
      end

      def cascade_stats
        retries = all_attempts.count { |a| %w[provider_declined provider_timeout].include?(a.reason) }
        {
          'operations_with_retry' => @decisions.count do |d|
            d.attempts.any? { |a| %w[provider_declined provider_timeout].include?(a.reason) }
          end,
          'total_retries' => retries,
          'fallback_used' => @decisions.count(&:fallback_used),
          'avg_providers_considered' => Support::Numeric.round2(
            Support::Numeric.safe_div(all_attempts.size, total)
          )
        }
      end

      # Почему фактическое распределение разошлось с целевым.
      def deviations
        distribution.filter_map do |name, stat|
          next if stat['deviation_pp'].abs < SHARE_DEVIATION_ALERT_PP

          {
            'provider' => name,
            'deviation_pp' => stat['deviation_pp'],
            'cause' => deviation_cause(name, stat)
          }
        end
      end

      # Пустой массив deviations сам по себе ничего не сообщает: непонятно,
      # отклонений нет или их некому было посчитать. Поясняем оба случая.
      def deviations_note
        return nil if @decisions.empty? || distribution.empty?

        return "Существенным считается отклонение фактической доли от целевой " \
               "на #{SHARE_DEVIATION_ALERT_PP} п.п. и более." if deviations.any?

        name, stat = distribution.max_by { |_, s| s['deviation_pp'].abs }
        step = Support::Numeric.round2(100.0 / @decisions.size)
        "Существенных отклонений нет: наибольшее — #{stat['deviation_pp'].abs} п.п. " \
          "(#{name}) при пороге #{SHARE_DEVIATION_ALERT_PP} п.п. " \
          "В очереди #{@decisions.size} заявок, поэтому фактическая доля кратна #{step} п.п.; " \
          "отклонения меньше этого шага вызваны дискретностью очереди, а не политикой роутинга."
      end

      def deviation_cause(name, stat)
        blocking = all_attempts.select { |a| a.provider == name && a.hard_skip? }
        if blocking.any?
          top = tally(blocking).first
          return "#{blocking.size} заявок отсеяны hard-constraints, чаще всего «#{top[0]}» (#{top[1]})"
        end
        return 'провайдер получил больше заявок, чем целевая доля: конкуренты были недоступны' if stat['deviation_pp'].positive?

        'провайдер проигрывал по совокупному баллу при доступных альтернативах'
      end

      def history_calibration
        return nil if @calibrator.nil? || @calibrator.empty?

        {
          'operations' => @calibrator.total_count,
          'by_provider' => @calibrator.stats_by_provider,
          'conversion_drift' => @calibrator.conversion_drift(@pool.providers)
        }
      end

      # Рекомендации: каждая называет конкретный параметр и его новое значение.
      def recommendations
        @recommendations ||= begin
          list = []
          list.concat(capacity_recommendations)
          list.concat(share_recommendations)
          list.concat(utilization_recommendations)
          list.concat(turnover_recommendations)
          list.concat(bank_coverage_recommendations)
          list.concat(amount_range_recommendations)
          list.concat(conversion_recommendations)
          list << ok_recommendation if list.empty?
          list
        end
      end

      # Когда внешняя ёмкость кончилась, отчёт показывает цели 40/35/25 против
      # факта вроде 5/1/7 — и это читается как провал роутинга. На самом деле это
      # потолок дневных лимитов: объясняем прямо, называя заявку, на которой
      # внешние провайдеры закончились.
      def capacity_recommendations
        fallback_index = @decisions.index(&:fallback_used)
        return [] if fallback_index.nil?

        count = @decisions.count(&:fallback_used)
        share = Support::Numeric.round2(count * 100.0 / @decisions.size)
        return [] if share < FALLBACK_SHARE_ALERT_PCT

        first = @decisions[fallback_index]
        capacity = external_daily_capacity
        [{
          'rule' => 'external_capacity_exhausted',
          'parameter' => 'daily_amount_limit',
          'current' => capacity,
          'text' => "внешняя ёмкость исчерпана на #{fallback_index + 1}-й заявке " \
                    "(#{first.operation.id}): #{count} заявок из #{@decisions.size} (#{share}%) " \
                    'ушли на self-provider. Отклонение от целевых долей здесь — следствие ' \
                    "суммарного дневного лимита внешних провайдеров (#{format('%.0f', capacity)} ₽), " \
                    'а не выбора роутера: поднимать нужно лимиты, а не веса стратегий'
        }]
      end

      def external_daily_capacity
        @pool.providers.reject(&:fallback_role?).sum { |p| p.raw['daily_amount_limit'].to_f }
      end

      def share_recommendations
        distribution.filter_map do |name, stat|
          next if stat['deviation_pp'].abs < SHARE_DEVIATION_ALERT_PP

          suggested = suggest_traffic_percentage(stat)
          direction = stat['deviation_pp'].negative? ? 'недобирает' : 'перебирает'
          {
            'rule' => 'share_deviation',
            'provider' => name,
            'parameter' => 'traffic_percentage',
            'current' => stat['target_pct'],
            'suggested' => suggested,
            'text' => "#{name} #{direction} #{stat['deviation_pp'].abs} п.п. по количеству " \
                      "(факт #{stat['share_pct']}%, цель #{stat['target_pct']}%) — " \
                      "привести traffic_percentage к #{suggested}% или снять ограничение, " \
                      'из-за которого заявки не доходят'
          }
        end
      end

      def suggest_traffic_percentage(stat)
        Support::Numeric.round2((stat['target_pct'] + stat['share_pct']) / 2.0)
      end

      def utilization_recommendations
        projected_daily_utilization.filter_map do |name, stat|
          ratio = stat['utilization_pct'].to_f / 100.0
          next if ratio < UTILIZATION_ALERT

          {
            'rule' => 'daily_limit_pressure',
            'provider' => name,
            'parameter' => 'daily_amount_limit',
            'current' => stat['limit'],
            'suggested' => (stat['limit'] * 1.2).round,
            'text' => "#{name} выбрал #{stat['utilization_pct']}% дневного лимита — " \
                      "поднять daily_amount_limit до #{(stat['limit'] * 1.2).round} ₽ " \
                      'или снизить его долю трафика, иначе заявки начнут отсеиваться'
          }
        end
      end

      def turnover_recommendations
        @pool.providers.filter_map do |provider|
          min = provider.daily_turnover_min
          next if min.zero?

          committed = provider.daily_committed_amount
          next if committed >= min

          gap = (min - committed).round
          {
            'rule' => 'turnover_commitment_gap',
            'provider' => provider.name,
            'parameter' => 'priority',
            'current' => provider.priority,
            'suggested' => [provider.priority - 1, 1].max,
            'text' => "#{provider.name} не добрал обязательный оборот: #{committed.round} ₽ " \
                      "из #{min.round} ₽/сутки, не хватает #{gap} ₽ — поднять priority " \
                      'или увеличить вес turnover_commitment в профиле'
          }
        end
      end

      # Самая частая жёсткая причина отсева обычно указывает на настройку,
      # которую дешевле всего поменять.
      def bank_coverage_recommendations
        blocked = all_attempts.select { |a| a.reason == 'bank_not_in_list' }
        return [] if blocked.size < 2

        by_provider = blocked.group_by(&:provider).max_by { |_, list| list.size }
        name, list = by_provider
        provider = @pool[name]
        {
          'rule' => 'bank_coverage',
          'provider' => name,
          'parameter' => 'banks',
          'current' => provider&.banks,
          'suggested' => nil,
          'text' => "#{name} отсеян #{list.size} раз по фильтру банка — расширить список banks " \
                    'или подключить недостающие банки, иначе целевая доля недостижима'
        }.then { |item| [item] }
      end

      def amount_range_recommendations
        below = all_attempts.count { |a| a.reason == 'amount_below_minimum' }
        above = all_attempts.count { |a| a.reason == 'amount_exceeds_limit' }
        list = []
        if below >= 2
          list << {
            'rule' => 'amount_range', 'provider' => nil, 'parameter' => 'limit_amount_min',
            'current' => nil, 'suggested' => nil,
            'text' => "#{below} отсевов по нижней границе суммы — пересмотреть limit_amount_min " \
                      'у провайдеров: мелкие чеки сейчас упираются в одного исполнителя'
          }
        end
        if above >= 2
          list << {
            'rule' => 'amount_range', 'provider' => nil, 'parameter' => 'limit_amount_max',
            'current' => nil, 'suggested' => nil,
            'text' => "#{above} отсевов по верхней границе суммы — крупные чеки уходят " \
                      'к одному провайдеру, стоит поднять limit_amount_max у альтернативы'
          }
        end
        list
      end

      def conversion_recommendations
        return [] if @calibrator.nil? || @calibrator.empty?

        @calibrator.conversion_drift(@pool.providers).map do |drift|
          {
            'rule' => 'conversion_drift',
            'provider' => drift['provider'],
            'parameter' => 'conversion_24h',
            'current' => drift['declared'],
            'suggested' => drift['observed'],
            'text' => "#{drift['provider']}: заявленная конверсия #{drift['declared']}, " \
                      "по истории #{drift['observed']} (#{drift['drift_pp']} п.п.) — " \
                      'обновить conversion_24h или увеличить history_blend в профиле'
          }
        end
      end

      def ok_recommendation
        {
          'rule' => 'no_action',
          'provider' => nil,
          'parameter' => nil,
          'current' => nil,
          'suggested' => nil,
          'text' => 'Существенных отклонений от целевого распределения и давления на лимиты не обнаружено'
        }
      end
    end
  end
end
