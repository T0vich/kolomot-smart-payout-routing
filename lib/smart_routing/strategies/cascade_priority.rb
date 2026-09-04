# frozen_string_literal: true

module SmartRouting
  module Strategies
    # Стратегия 3: очередь в каскаде по priority.
    #
    # Ранг считается среди доступных кандидатов, а не по всему списку:
    # если провайдер с priority 1 отсеян hard-constraints, первым в каскаде
    # становится следующий, и он получает полный балл.
    class CascadePriority < Base
      def self.key = 'cascade_priority'
      def self.title = 'Очередь в каскаде'

      def score(candidates, _operation, _pool)
        return {} if candidates.empty?
        return { candidates.first.name => 1.0 } if candidates.size == 1

        ordered = candidates.sort_by { |c| [c.priority, c.name] }
        last_index = ordered.size - 1
        ordered.each_with_index.to_h do |candidate, index|
          [candidate.name, 1.0 - (index.to_f / last_index)]
        end
      end

      def explain(provider, _operation, _pool)
        "priority #{provider.priority} в каскаде"
      end
    end
  end
end
