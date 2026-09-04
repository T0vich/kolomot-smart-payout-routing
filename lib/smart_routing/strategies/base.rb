# frozen_string_literal: true

module SmartRouting
  module Strategies
    # Базовый класс мягкой цели (soft-goal).
    #
    # Стратегия не отсеивает провайдеров — она только ранжирует уже допустимых.
    # Оценка считается сразу по всему списку кандидатов, потому что часть
    # сигналов имеет смысл только в сравнении (позиция в каскаде, конверсия
    # относительно конкурентов, вклад в отклонение долей).
    #
    # Контракт: #score возвращает { имя_провайдера => Float в [0..1] },
    # где 1.0 — самый предпочтительный кандидат.
    class Base
      include Support::Numeric

      attr_reader :config

      def initialize(config)
        @config = config
      end

      def self.key
        raise NotImplementedError, "#{name} должен определить .key"
      end

      # Короткое название для отчёта и объяснений.
      def self.title
        raise NotImplementedError, "#{name} должен определить .title"
      end

      def key = self.class.key
      def title = self.class.title

      # @param candidates [Array<Models::Provider>]
      # @return [Hash{String=>Float}]
      def score(_candidates, _operation, _pool)
        raise NotImplementedError, "#{self.class.name} должен определить #score"
      end

      # Человекочитаемое пояснение вклада стратегии в выбор конкретного провайдера.
      def explain(provider, _operation, _pool)
        "#{title}: без пояснения для #{provider.name}"
      end

      private

      def zeroed(candidates, value = 0.5)
        candidates.to_h { |c| [c.name, value] }
      end
    end
  end
end
