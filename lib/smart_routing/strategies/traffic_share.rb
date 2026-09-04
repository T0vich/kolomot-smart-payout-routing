# frozen_string_literal: true

module SmartRouting
  module Strategies
    # Стратегия 1: процент от количества заявок (traffic_percentage).
    #
    # Вместо наивного «у кого меньше заявок» считаем, насколько уменьшится
    # суммарное отклонение фактических долей от целевых, если отдать заявку
    # именно этому кандидату. Это устойчиво к любому числу провайдеров
    # и к тому, что часть из них недоступна по hard-constraints.
    class TrafficShare < Base
      def self.key = 'traffic_share'
      def self.title = 'Доля по количеству заявок'

      def score(candidates, operation, pool)
        errors = candidates.to_h do |candidate|
          [candidate.name, pool.share_error_after(:count, candidate, operation.amount)]
        end
        contrast_inverse(errors)
      end

      def explain(provider, _operation, pool)
        actual = pct(pool.share(:count, provider.name), 1.0)
        target = provider.traffic_percentage
        delta = round2(actual - target)
        direction = delta.negative? ? 'недобирает' : 'перебирает'
        "доля по количеству #{actual}% при цели #{target}% (#{direction} #{delta.abs} п.п.)"
      end
    end
  end
end
