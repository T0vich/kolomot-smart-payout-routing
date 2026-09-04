# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Дневной максимум оборота.
    #
    # Считаем не только подтверждённый оборот, но и зарезервированный под
    # заявки «в полёте»: иначе можно продать один и тот же лимит дважды.
    class DailyAmountLimit < Base
      def self.key = 'daily_amount_limit'

      def check(provider, operation, _pool)
        limit = provider.daily_amount_limit
        return nil if limit.nil?

        committed = provider.daily_committed_amount
        return nil if committed + operation.amount <= limit.to_f

        reject_with('daily_limit_exceeded',
             "#{money(committed)} + #{money(operation.amount)} > daily_amount_limit #{money(limit)}")
      end
    end
  end
end
