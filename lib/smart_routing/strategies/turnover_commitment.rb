# frozen_string_literal: true

module SmartRouting
  module Strategies
    # Стратегия 7: финансовые обязательства по обороту.
    #
    # Гейт часто выдают на условиях «не менее X ₽/сутки» — недобор такого
    # минимума стоит денег, поэтому непокрытое обязательство поднимает
    # провайдера, а приближение к верхней границе опускает.
    #
    # Шкала: [0.6..1.0] — минимум ещё не набран (чем больше недобор, тем выше),
    #        [0.0..0.5] — минимум закрыт, балл падает по мере приближения к максимуму.
    class TurnoverCommitment < Base
      def self.key = 'turnover_commitment'
      def self.title = 'Фин. обязательства по обороту'

      def score(candidates, _operation, _pool)
        candidates.to_h { |candidate| [candidate.name, value_for(candidate)] }
      end

      def explain(provider, _operation, _pool)
        committed = provider.daily_committed_amount
        min = provider.daily_turnover_min
        max = provider.daily_turnover_max

        if min.positive? && committed < min
          "оборот #{format('%.0f', committed)} ₽ из обязательных #{format('%.0f', min)} ₽/сутки — недобор"
        elsif max
          "оборот #{format('%.0f', committed)} ₽ при потолке #{format('%.0f', max)} ₽/сутки"
        elsif min.positive?
          "обязательство #{format('%.0f', min)} ₽/сутки выполнено"
        else
          'обязательств по обороту нет'
        end
      end

      private

      def value_for(provider)
        committed = provider.daily_committed_amount
        min = provider.daily_turnover_min
        max = provider.daily_turnover_max

        if min.positive? && committed < min
          deficit_ratio = clamp01((min - committed) / min)
          return 0.6 + (0.4 * deficit_ratio)
        end

        return 0.5 if max.nil?

        headroom = clamp01(1.0 - (committed / max.to_f))
        0.5 * headroom
      end
    end
  end
end
