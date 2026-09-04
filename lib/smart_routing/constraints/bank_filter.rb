# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Фильтр по банку получателя.
    #
    # Пустой список banks означает «работаем со всеми».
    # exclude_banks переворачивает смысл списка в чёрный.
    class BankFilter < Base
      def self.key = 'bank_filter'

      def check(provider, operation, _pool)
        banks = provider.banks
        return nil if banks.empty?

        bank = operation.bank
        if provider.exclude_banks?
          return nil unless banks.include?(bank)

          reject_with('bank_in_exclude_list', "#{bank} входит в exclude_banks [#{banks.join(', ')}]")
        else
          return nil if banks.include?(bank)

          reject_with('bank_not_in_list', "#{bank || 'банк не указан'} отсутствует в banks [#{banks.join(', ')}]")
        end
      end
    end
  end
end
