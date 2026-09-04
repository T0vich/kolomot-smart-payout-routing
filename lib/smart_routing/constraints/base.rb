# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Результат проверки одного жёсткого ограничения.
    Verdict = Struct.new(:ok, :reason, :details, keyword_init: true) do
      def ok? = ok
    end

    # Базовый класс hard-constraint.
    #
    # Контракт прост: `check` возвращает nil, если провайдер проходит,
    # либо Verdict с машинным reason и человекочитаемым details.
    # Новое правило допуска = новый наследник + строка в Registry и конфиге.
    class Base
      attr_reader :options

      def initialize(options = {})
        @options = options || {}
      end

      # @return [String] ключ правила в config/routing.yml
      def self.key
        raise NotImplementedError, "#{name} должен определить .key"
      end

      def key = self.class.key

      # @return [Verdict, nil]
      def check(_provider, _operation, _pool)
        raise NotImplementedError, "#{self.class.name} должен определить #check"
      end

      private

      def reject_with(reason, details)
        Verdict.new(ok: false, reason: reason, details: details)
      end

      def money(value)
        format('%.0f', value.to_f)
      end
    end
  end
end
