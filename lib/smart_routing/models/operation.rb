# frozen_string_literal: true

module SmartRouting
  module Models
    # Заявка на выплату из operations_queue*.json.
    class Operation
      attr_reader :id, :amount, :bank, :card_brand, :created_at, :payout_requisite, :raw

      def self.from_json(hash, index: 0)
        unless hash.is_a?(Hash)
          raise InvalidDataError, "Элемент очереди ##{index} должен быть объектом, получено #{hash.class}"
        end

        id = hash['operation_id']
        raise InvalidDataError, "Элемент очереди ##{index}: отсутствует operation_id" if id.nil? || id.to_s.empty?

        amount = hash['amount']
        unless amount.is_a?(::Numeric) && amount.positive?
          raise InvalidDataError, "#{id}: amount должен быть положительным числом, получено #{amount.inspect}"
        end

        new(hash)
      end

      def initialize(hash)
        @raw = hash
        @id = hash['operation_id'].to_s
        @amount = hash['amount'].to_f
        @bank = hash['bank']&.to_s
        @card_brand = hash['card_brand']
        @payout_requisite = hash['payout_requisite']
        @created_at = parse_time(hash['created_at'])
      end

      def to_s
        format('%s (%.0f ₽, %s)', id, amount, bank || 'банк не указан')
      end

      private

      def parse_time(value)
        return nil if value.nil? || value.to_s.empty?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
