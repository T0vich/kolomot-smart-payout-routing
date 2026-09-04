# frozen_string_literal: true

module SmartRouting
  module Models
    # Платёжный провайдер: снимок из providers.json + поля, доопределённые
    # в config/routing.yml (volume_share_pct, requests_per_minute_limit,
    # daily_turnover_min/max, role), + изменяемое состояние прогона.
    class Provider
      REQUIRED_FIELDS = %w[payment_system status].freeze

      attr_reader :name, :raw, :extension
      attr_accessor :in_progress_count, :in_progress_amount, :daily_approved_amount,
                    :daily_reserved_amount, :available_requisites, :routed_count, :routed_amount,
                    :approved_count, :failed_count

      def self.from_json(hash, extension: {}, index: 0)
        unless hash.is_a?(Hash)
          raise InvalidDataError, "providers[#{index}] должен быть объектом, получено #{hash.class}"
        end

        REQUIRED_FIELDS.each do |field|
          raise InvalidDataError, "providers[#{index}]: отсутствует поле #{field}" unless hash.key?(field)
        end

        new(hash, extension: extension)
      end

      def initialize(hash, extension: {})
        @raw = hash
        @extension = extension || {}
        @name = hash['payment_system'].to_s

        @in_progress_count = hash['in_progress_count'].to_i
        @in_progress_amount = hash['in_progress_amount'].to_f
        @daily_approved_amount = hash['daily_approved_amount'].to_f
        @daily_reserved_amount = 0.0
        @available_requisites = hash['available_requisites'].to_i

        @routed_count = 0
        @routed_amount = 0.0
        @approved_count = 0
        @failed_count = 0
      end

      # --- неизменяемые характеристики снимка ---

      def status = raw['status'].to_s
      def active? = status == 'active'
      def traffic_percentage = raw['traffic_percentage'].to_f
      def priority = (raw['priority'] || extension['priority'] || 99).to_i
      def limit_amount_min = raw['limit_amount_min']
      def limit_amount_max = raw['limit_amount_max']
      def daily_amount_limit = raw['daily_amount_limit']
      def in_progress_count_limit = raw['in_progress_count_limit']
      def in_progress_amount_limit = raw['in_progress_amount_limit']
      def conversion_24h = raw['conversion_24h'].to_f
      def avg_latency_sec = (raw['avg_latency_sec'] || 45).to_f
      def banks = Array(raw['banks'])
      def exclude_banks? = raw['exclude_banks'] == true
      def provider_margin_pct = raw['provider_margin_pct'].to_f
      def merchant_margin_pct = raw['merchant_margin_pct'].to_f
      def allow_negative_agreement? = raw['allow_negative_agreement'] == true

      # --- поля, доопределённые конфигом ---

      # Целевая доля по объёму. Если не задана — падаем обратно на долю по количеству.
      def volume_share_pct
        (extension['volume_share_pct'] || traffic_percentage).to_f
      end

      def requests_per_minute_limit
        value = extension['requests_per_minute_limit']
        value.nil? ? nil : value.to_i
      end

      def daily_turnover_min = (extension['daily_turnover_min'] || 0).to_f
      def daily_turnover_max = extension['daily_turnover_max']

      # self-provider используется только как запасной вариант, вне общего пула.
      def fallback_role? = extension['role'].to_s == 'fallback'

      # --- текущее состояние ---

      # Занятый дневной лимит: подтверждённое + зарезервированное под in-flight.
      def daily_committed_amount
        daily_approved_amount + daily_reserved_amount
      end

      def daily_utilization
        return 0.0 if daily_amount_limit.nil? || daily_amount_limit.to_f.zero?

        daily_committed_amount / daily_amount_limit.to_f
      end

      def in_progress_count_utilization
        return 0.0 if in_progress_count_limit.nil? || in_progress_count_limit.to_i.zero?

        in_progress_count.to_f / in_progress_count_limit.to_f
      end

      def in_progress_amount_utilization
        return 0.0 if in_progress_amount_limit.nil? || in_progress_amount_limit.to_f.zero?

        in_progress_amount / in_progress_amount_limit.to_f
      end

      def requisites_utilization
        total = raw['available_requisites'].to_i
        return 0.0 if total.zero?

        1.0 - (available_requisites.to_f / total)
      end

      # Самое узкое место провайдера прямо сейчас — им и меряем загрузку.
      def utilization
        [daily_utilization, in_progress_count_utilization,
         in_progress_amount_utilization, requisites_utilization].max
      end

      def to_s = name

      def snapshot
        {
          'payment_system' => name,
          'status' => status,
          'daily_approved_amount' => daily_approved_amount,
          'daily_reserved_amount' => daily_reserved_amount,
          'daily_amount_limit' => daily_amount_limit,
          'in_progress_count' => in_progress_count,
          'in_progress_amount' => in_progress_amount,
          'available_requisites' => available_requisites,
          'routed_count' => routed_count,
          'routed_amount' => routed_amount,
          'approved_count' => approved_count,
          'failed_count' => failed_count
        }
      end
    end
  end
end
