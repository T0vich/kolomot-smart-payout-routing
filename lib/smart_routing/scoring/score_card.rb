# frozen_string_literal: true

module SmartRouting
  module Scoring
    # Разложение итогового балла провайдера по слагаемым.
    #
    # Хранится вместе с решением и попадает в routing_decisions.json —
    # именно это делает выбор проверяемым, а не «доверьтесь скорингу».
    class ScoreCard
      attr_reader :provider_name, :parts, :weights, :total

      def initialize(provider_name:, parts:, weights:)
        @provider_name = provider_name
        @parts = parts
        @weights = weights
        @total = compute_total
      end

      # Вклад стратегии в итог: нормированный балл × нормированный вес.
      def contribution(key)
        weight = weights[key].to_f
        return 0.0 if weight_sum.zero?

        parts[key].to_f * weight / weight_sum
      end

      # Стратегии по убыванию вклада — «почему выбран именно он».
      def ranked_parts
        parts.keys.sort_by { |key| -contribution(key) }
      end

      def dominant_key = ranked_parts.first

      def to_h
        parts.keys.to_h do |key|
          [key, {
            'score' => Support::Numeric.round2(parts[key]),
            'weight' => Support::Numeric.round2(weights[key]),
            'contribution' => Support::Numeric.round2(contribution(key))
          }]
        end
      end

      # Компактная человекочитаемая расшифровка для поля details.
      def to_sentence(strategies_by_key = {})
        ranked_parts.map do |key|
          title = strategies_by_key[key]&.title || key
          format('%s %.2f×%.2f', title, parts[key].to_f, weights[key].to_f)
        end.join(', ')
      end

      private

      def weight_sum
        @weight_sum ||= weights.values.map(&:to_f).sum
      end

      def compute_total
        return 0.0 if weight_sum.zero?

        parts.sum { |key, value| value.to_f * weights[key].to_f } / weight_sum
      end
    end
  end
end
