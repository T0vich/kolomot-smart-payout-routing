# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Лимиты одновременно обрабатываемых заявок — по количеству и по сумме.
    class InProgress < Base
      def self.key = 'in_progress'

      def check(provider, operation, _pool)
        count_limit = provider.in_progress_count_limit
        if count_limit && provider.in_progress_count + 1 > count_limit.to_i
          return reject_with('in_progress_count_limit',
                      "#{provider.in_progress_count} + 1 > in_progress_count_limit #{count_limit}")
        end

        amount_limit = provider.in_progress_amount_limit
        return nil if amount_limit.nil?
        return nil if provider.in_progress_amount + operation.amount <= amount_limit.to_f

        reject_with('in_progress_amount_limit',
             "#{money(provider.in_progress_amount)} + #{money(operation.amount)} " \
             "> in_progress_amount_limit #{money(amount_limit)}")
      end
    end
  end
end
