# frozen_string_literal: true

module SmartRouting
  module Models
    # Заявка на выплату из operations_queue*.json.
    class Operation
      attr_reader :id, :amount, :bank, :card_brand, :created_at, :payout_requisite, :raw, :defect

      # Суммы строкой ("15000") в платёжных выгрузках встречаются постоянно,
      # и это не повод считать заявку битой.
      NUMERIC_STRING = /\A\s*-?\d+(?:[.,]\d+)?\s*\z/.freeze

      # Строгий разбор: используется тестами и там, где битая заявка —
      # действительно повод остановиться.
      def self.from_json(hash, index: 0)
        defect = defect_for(hash, index)
        raise InvalidDataError, defect if defect

        new(hash)
      end

      # Мягкий разбор для боевого прогона. Заявку, которую нельзя разобрать,
      # мы не выбрасываем: решение по ней всё равно попадёт в сдаваемый файл,
      # иначе одна битая строка стоит нам всей очереди.
      def self.parse(hash, index: 0)
        defect = defect_for(hash, index)
        return new(hash) if defect.nil?

        payload = hash.is_a?(Hash) ? hash.dup : {}
        payload['operation_id'] = payload['operation_id'].to_s.empty? ? "unknown_#{index}" : payload['operation_id']
        new(payload, defect: defect)
      end

      # @return [String, nil] описание проблемы или nil, если заявка годная
      def self.defect_for(hash, index)
        unless hash.is_a?(Hash)
          return "Элемент очереди ##{index} должен быть объектом, получено #{hash.class}"
        end

        id = hash['operation_id']
        return "Элемент очереди ##{index}: отсутствует operation_id" if id.nil? || id.to_s.empty?

        amount = coerce_amount(hash['amount'])
        return "#{id}: amount должен быть положительным числом, получено #{hash['amount'].inspect}" if amount.nil?

        nil
      end

      # @return [Float, nil] сумма, если её удалось привести к положительному числу
      def self.coerce_amount(value)
        number =
          case value
          when ::Numeric then value.to_f
          when ::String then value.match?(NUMERIC_STRING) ? value.strip.tr(',', '.').to_f : nil
          end

        number if number&.positive?
      end

      def initialize(hash, defect: nil)
        @raw = hash
        @defect = defect
        @id = hash['operation_id'].to_s
        @amount = self.class.coerce_amount(hash['amount']) || 0.0
        @bank = hash['bank']&.to_s
        @card_brand = hash['card_brand']
        @payout_requisite = hash['payout_requisite']
        @created_at = parse_time(hash['created_at'])
      end

      def defect? = !defect.nil?

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
