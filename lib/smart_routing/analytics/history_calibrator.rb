# frozen_string_literal: true

module SmartRouting
  module Analytics
    # Разбор operations_history.csv: что реально происходило вчера.
    #
    # Даёт три вещи:
    #   * фактическую конверсию провайдера — ею можно смешать conversion_24h;
    #   * фактические доли по количеству и объёму — их сравниваем с целевыми;
    #   * профиль отказов и просрочек — попадает в рекомендации.
    class HistoryCalibrator
      TERMINAL_STATUSES = %w[approved rejected expired].freeze

      attr_reader :rows

      def self.load(path)
        new(Support::CsvReader.read(path))
      end

      def initialize(rows)
        @rows = Array(rows).select { |row| TERMINAL_STATUSES.include?(row['status']) }
      end

      def empty? = rows.empty?

      def total_count = rows.size

      def total_amount
        @total_amount ||= rows.sum { |row| row['amount'].to_f }
      end

      def providers
        @providers ||= rows.map { |row| row['payment_system'] }.compact.uniq.sort
      end

      # @return [Hash{String=>Float}] доля успешных операций провайдера
      def conversion_by_provider
        @conversion_by_provider ||= providers.to_h do |name|
          subset = rows_for(name)
          approved = subset.count { |row| row['status'] == 'approved' }
          [name, Support::Numeric.safe_div(approved, subset.size)]
        end
      end

      def stats_by_provider
        @stats_by_provider ||= providers.to_h do |name|
          subset = rows_for(name)
          amount = subset.sum { |row| row['amount'].to_f }
          [name, {
            'count' => subset.size,
            'amount' => amount,
            'count_share_pct' => Support::Numeric.pct(subset.size, total_count),
            'volume_share_pct' => Support::Numeric.pct(amount, total_amount),
            'approved' => subset.count { |row| row['status'] == 'approved' },
            'rejected' => subset.count { |row| row['status'] == 'rejected' },
            'expired' => subset.count { |row| row['status'] == 'expired' },
            'conversion' => Support::Numeric.round2(conversion_by_provider[name]),
            'avg_latency_sec' => Support::Numeric.round2(
              Support::Numeric.safe_div(subset.sum { |row| row['latency_sec'].to_f }, subset.size)
            )
          }]
        end
      end

      # Прогрев счётчиков долей: используется, когда очередь продолжает
      # уже начатый день (config: warm_start).
      def warm_start
        stats_by_provider.transform_values { |stat| { 'count' => stat['count'], 'amount' => stat['amount'] } }
      end

      # Расхождение снимка с фактом: если conversion_24h заметно расходится
      # с историей, это повод пересмотреть вес конверсии.
      def conversion_drift(providers_list)
        providers_list.filter_map do |provider|
          observed = conversion_by_provider[provider.name]
          next if observed.nil?

          drift = observed - provider.conversion_24h
          next if drift.abs < 0.05

          {
            'provider' => provider.name,
            'declared' => provider.conversion_24h,
            'observed' => Support::Numeric.round2(observed),
            'drift_pp' => Support::Numeric.round2(drift * 100)
          }
        end
      end

      private

      def rows_for(name)
        rows.select { |row| row['payment_system'] == name }
      end
    end
  end
end
