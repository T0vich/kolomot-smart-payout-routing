# frozen_string_literal: true

module SmartRouting
  module Analytics
    # Переигрывание истории: что было бы, если бы эти 100 операций
    # прошли через наш роутер.
    #
    # Метрика сравнения выбрана так, чтобы не быть замкнутой на себя:
    # ожидаемая конверсия считается по фактической успешности провайдеров
    # из той же истории, а не по симулятору. То есть мы сравниваем
    # «куда отправили мы» с «куда отправили тогда», а качество обоих
    # маршрутов меряем одними и теми же наблюдаемыми числами.
    #
    # Ограничение метода: снимок providers.json сделан на следующий день,
    # поэтому лимиты и обороты в нём не совпадают с моментом истории.
    # Абсолютные значения тут ориентировочные, сравнимы именно доли.
    class Backtest
      Result = Struct.new(:rows, :decisions, :pool, :observed_conversion, keyword_init: true)

      # @param reset_daily [Boolean] обнулить дневные счётчики перед прогоном.
      #   Снимок сделан на конец следующего дня — у payflow дневной лимит выбран
      #   на 97%. Переигрывать целый день имеет смысл только с начала дня,
      #   иначе сравнение говорит не о качестве роутинга, а о возрасте снимка.
      def initialize(config:, providers_path:, history_path:, reset_daily: true)
        @config = config
        @providers_path = providers_path
        @history_path = history_path
        @reset_daily = reset_daily
      end

      def run
        calibrator = HistoryCalibrator.load(@history_path)
        rows = calibrator.rows.sort_by { |row| row['created_at'].to_s }
        operations = rows.map { |row| operation_from(row) }

        providers = Loaders.providers(@providers_path, @config)
        reset_daily_counters(providers) if @reset_daily
        pool = ProviderPool.new(providers, config: @config)
        scorer = Scoring::CompositeScorer.new(
          @config, Strategies::Registry.build(@config, observed_conversion: calibrator.conversion_by_provider)
        )
        router = Router.new(pool: pool, config: @config, scorer: scorer, simulator: Simulator.new(@config))

        decisions = operations.map do |operation|
          router.route(operation)
        rescue NoProviderError
          nil
        end.compact
        pool.drain!

        build_report(rows, decisions, pool, calibrator)
      end

      private

      def reset_daily_counters(providers)
        providers.each do |provider|
          provider.daily_approved_amount = 0.0
          provider.daily_reserved_amount = 0.0
          provider.in_progress_count = 0
          provider.in_progress_amount = 0.0
        end
      end

      def operation_from(row)
        Models::Operation.new(
          'operation_id' => row['operation_id'],
          'created_at' => row['created_at'],
          'amount' => row['amount'].to_f,
          'bank' => row['bank']
        )
      end

      def build_report(rows, decisions, pool, calibrator)
        observed = calibrator.conversion_by_provider
        targets = pool.routable.to_h { |p| [p.name, p.traffic_percentage] }

        actual_counts = rows.group_by { |row| row['payment_system'] }.transform_values(&:size)
        ours_counts = decisions.group_by(&:selected_provider).transform_values(&:size)

        {
          'operations' => rows.size,
          'reset_daily' => @reset_daily,
          'routed_by_us' => decisions.size,
          'unroutable' => rows.size - decisions.size,
          'note' => note_text,
          'distribution' => distribution_table(targets, actual_counts, ours_counts, rows.size, decisions.size),
          'share_error_pp' => {
            'historical' => share_error(targets, actual_counts, rows.size),
            'ours' => share_error(targets, ours_counts, decisions.size)
          },
          'expected_conversion' => {
            'historical' => Support::Numeric.round2(
              Support::Numeric.safe_div(rows.count { |r| r['status'] == 'approved' }, rows.size)
            ),
            'ours' => Support::Numeric.round2(
              Support::Numeric.safe_div(
                decisions.sum { |d| observed.fetch(d.selected_provider, 0.0) }, decisions.size
              )
            )
          },
          'misrouted_by_hard_constraints' => misrouted(rows, decisions)
        }
      end

      def note_text
        base = 'Снимок providers.json сделан позже истории, поэтому сравнимы доли ' \
               'и ожидаемая конверсия, а не абсолютные обороты'
        return "#{base}. Дневные счётчики обнулены: день переигрывается с начала" if @reset_daily

        "#{base}. Дневные счётчики взяты из снимка как есть"
      end

      def distribution_table(targets, actual_counts, ours_counts, actual_total, ours_total)
        (targets.keys | actual_counts.keys | ours_counts.keys).sort.to_h do |name|
          [name, {
            'target_pct' => targets[name],
            'historical_pct' => Support::Numeric.pct(actual_counts.fetch(name, 0), actual_total),
            'ours_pct' => Support::Numeric.pct(ours_counts.fetch(name, 0), ours_total),
            'historical_count' => actual_counts.fetch(name, 0),
            'ours_count' => ours_counts.fetch(name, 0)
          }]
        end
      end

      # Суммарное отклонение от целевых долей в процентных пунктах.
      def share_error(targets, counts, total)
        return 0.0 if total.zero?

        Support::Numeric.round2(
          targets.sum { |name, target| (Support::Numeric.pct(counts.fetch(name, 0), total) - target.to_f).abs }
        )
      end

      # Сколько исторических операций ушло провайдеру, который по нынешним
      # правилам вообще не должен был их принимать.
      def misrouted(rows, decisions)
        by_id = decisions.to_h { |d| [d.operation.id, d] }
        rows.count do |row|
          decision = by_id[row['operation_id']]
          next false if decision.nil?

          historical = row['payment_system']
          !decision.eligible.include?(historical) && historical != decision.selected_provider
        end
      end
    end
  end
end
