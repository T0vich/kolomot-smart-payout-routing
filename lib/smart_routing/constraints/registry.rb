# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Реестр жёстких ограничений.
    #
    # Добавить новое правило допуска = написать класс и зарегистрировать его
    # здесь. Порядок в ALL — это порядок проверки: сначала дешёвые и самые
    # частые причины отсева, чтобы details в attempts был наглядным.
    module Registry
      ALL = [
        Status,
        AmountRange,
        BankFilter,
        DailyAmountLimit,
        TurnoverMax,
        InProgress,
        Requisites,
        Margin,
        RateLimit
      ].freeze

      module_function

      def keys = ALL.map(&:key)

      def build(config)
        enabled = config.enabled_constraints
        ALL.select { |klass| enabled.include?(klass.key) }
           .map { |klass| klass.new(config.constraint_options(klass.key)) }
      end
    end

    # Цепочка проверок: первый несработавший constraint останавливает разбор.
    class Chain
      attr_reader :constraints

      def initialize(constraints)
        @constraints = constraints
      end

      # @return [Verdict, nil] nil — провайдер допущен
      def check(provider, operation, pool)
        constraints.each do |constraint|
          verdict = constraint.check(provider, operation, pool)
          return verdict if verdict && !verdict.ok?
        end
        nil
      end
    end
  end
end
