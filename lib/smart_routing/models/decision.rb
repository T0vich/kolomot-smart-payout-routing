# frozen_string_literal: true

module SmartRouting
  module Models
    # Итоговое решение по одной заявке — строка routing_decisions.json.
    class Decision
      attr_reader :operation, :selected_provider, :attempts, :simulated_result,
                  :latency_sec, :eligible, :profile, :fallback_used

      def initialize(operation:, selected_provider:, attempts:, simulated_result:, latency_sec:,
                     eligible:, profile:, fallback_used: false)
        @operation = operation
        @selected_provider = selected_provider
        @attempts = attempts
        @simulated_result = simulated_result
        @latency_sec = latency_sec
        @eligible = eligible
        @profile = profile
        @fallback_used = fallback_used
      end

      def approved?
        simulated_result == 'approved'
      end

      def amount
        operation.amount
      end

      # Формат из ТЗ + дополнительные поля для объяснимости
      # (валидатор организаторов лишние ключи не запрещает).
      def to_h
        {
          'operation_id' => operation.id,
          'selected_provider' => selected_provider,
          'attempts' => attempts.map(&:to_h),
          'simulated_result' => simulated_result,
          'latency_sec' => latency_sec,
          'amount' => operation.amount,
          'bank' => operation.bank,
          'eligible_providers' => eligible,
          'routing_profile' => profile,
          'fallback_used' => fallback_used
        }
      end
    end
  end
end
