# frozen_string_literal: true

module SmartRouting
  module Scoring
    # Совместный учёт нескольких целей: взвешенная сумма нормированных
    # под-скоров + явное правило разрешения ничьи.
    #
    # Порядок разрешения конфликта задан в конфиге (conflict_order) и по
    # умолчанию таков: фин. обязательства → доли по количеству → конверсия →
    # доли по объёму → каскад → диапазон суммы → загрузка.
    # Обязательство по обороту стоит выше целевых долей, потому что за него
    # платят по договору, а доля — ориентир, который можно добрать позже.
    class CompositeScorer
      attr_reader :config, :strategies

      def initialize(config, strategies)
        @config = config
        @strategies = strategies
        @by_key = strategies.to_h { |s| [s.key, s] }
      end

      def strategies_by_key = @by_key

      # @return [Array<Array(Models::Provider, ScoreCard)>] по убыванию предпочтения
      def rank(candidates, operation, pool)
        return [] if candidates.empty?

        weights = config.weights
        per_strategy = strategies.to_h do |strategy|
          [strategy.key, normalize_scores(strategy.score(candidates, operation, pool), candidates)]
        end

        cards = candidates.map do |candidate|
          parts = per_strategy.transform_values { |scores| scores[candidate.name].to_f }
          [candidate, ScoreCard.new(provider_name: candidate.name, parts: parts, weights: weights)]
        end

        cards.sort { |a, b| compare(a, b) }
      end

      # Почему победитель обошёл ближайшего конкурента — в одной фразе.
      def explain_win(winner_card, runner_up_card)
        return 'единственный допустимый провайдер' if runner_up_card.nil?

        gap = winner_card.total - runner_up_card.total
        if gap.abs <= config.tie_break_epsilon
          key = decisive_key(winner_card, runner_up_card)
          title = @by_key[key]&.title || key
          return format('ничья по общему баллу (%.2f против %.2f), решил приоритет политики «%s»',
                        winner_card.total, runner_up_card.total, title)
        end

        key = winner_card.dominant_key
        title = @by_key[key]&.title || key
        format('балл %.2f против %.2f у %s; основной вклад — «%s»',
               winner_card.total, runner_up_card.total, runner_up_card.provider_name, title)
      end

      private

      # Стратегия по каждому кандидату может вернуть неполный хеш —
      # добиваем нейтральным 0.5, чтобы отсутствие сигнала не читалось как ноль.
      def normalize_scores(scores, candidates)
        candidates.to_h { |c| [c.name, scores.fetch(c.name, 0.5)] }
      end

      def compare(left, right)
        left_provider, left_card = left
        right_provider, right_card = right

        gap = right_card.total - left_card.total
        return gap.positive? ? 1 : -1 if gap.abs > config.tie_break_epsilon

        key = decisive_key(left_card, right_card)
        if key
          diff = right_card.parts[key].to_f - left_card.parts[key].to_f
          return diff.positive? ? 1 : -1 unless diff.zero?
        end

        # Последний детерминированный рубеж: каскад, затем имя.
        [left_provider.priority, left_provider.name] <=> [right_provider.priority, right_provider.name]
      end

      # Первая политика из conflict_order, по которой кандидаты реально различаются.
      def decisive_key(left_card, right_card)
        config.conflict_order.find do |key|
          next false unless left_card.parts.key?(key)

          (left_card.parts[key].to_f - right_card.parts[key].to_f).abs > 1e-9
        end
      end
    end
  end
end
