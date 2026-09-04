# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Верхняя граница фин. обязательства: «не более X ₽/сутки на провайдера».
    #
    # Отличается от daily_amount_limit тем, что это условие договора, а не
    # техническая ёмкость гейта, и задаётся в конфиге, а не в снимке провайдера.
    class TurnoverMax < Base
      def self.key = 'turnover_max'

      def check(provider, operation, _pool)
        limit = provider.daily_turnover_max
        return nil if limit.nil?

        committed = provider.daily_committed_amount
        return nil if committed + operation.amount <= limit.to_f

        reject_with('daily_turnover_max_reached',
             "#{money(committed)} + #{money(operation.amount)} > daily_turnover_max #{money(limit)}")
      end
    end
  end
end
