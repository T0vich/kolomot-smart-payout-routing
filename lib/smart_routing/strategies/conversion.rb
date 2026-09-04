# frozen_string_literal: true

module SmartRouting
  module Strategies
    # Стратегия 5: приоритизация по конверсии.
    #
    # conversion_24h из снимка можно смешать с фактической конверсией,
    # посчитанной по operations_history.csv — доля истории задаётся
    # ключом history_blend в конфиге. Разброс конверсий узкий (0.79–0.91),
    # поэтому сигнал нормируется относительно текущих кандидатов,
    # иначе он полностью тонет в остальных слагаемых.
    class Conversion < Base
      def self.key = 'conversion'
      def self.title = 'Конверсия'

      def initialize(config, observed: {})
        super(config)
        @observed = observed || {}
      end

      def score(candidates, _operation, _pool)
        values = candidates.to_h { |candidate| [candidate.name, effective(candidate)] }
        contrast(values)
      end

      def explain(provider, _operation, _pool)
        base = "conversion_24h #{provider.conversion_24h}"
        observed = @observed[provider.name]
        return base if observed.nil? || config.history_blend.zero?

        "#{base}, по истории #{round2(observed)} (смешано #{config.history_blend})"
      end

      # Конверсия, которой пользуется скоринг: снимок, смешанный с историей.
      def effective(provider)
        blend = clamp01(config.history_blend)
        observed = @observed[provider.name]
        return provider.conversion_24h if observed.nil? || blend.zero?

        (provider.conversion_24h * (1 - blend)) + (observed.to_f * blend)
      end
    end
  end
end
