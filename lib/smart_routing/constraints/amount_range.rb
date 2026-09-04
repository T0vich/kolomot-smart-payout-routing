# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Сумма чека должна попадать в диапазон провайдера.
    class AmountRange < Base
      def self.key = 'amount_range'

      def check(provider, operation, _pool)
        min = provider.limit_amount_min
        max = provider.limit_amount_max

        if min && operation.amount < min
          return reject_with('amount_below_minimum', "#{money(operation.amount)} < limit_amount_min #{money(min)}")
        end
        return nil unless max && operation.amount > max

        reject_with('amount_exceeds_limit', "#{money(operation.amount)} > limit_amount_max #{money(max)}")
      end
    end
  end
end
