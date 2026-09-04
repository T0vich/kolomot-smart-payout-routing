# frozen_string_literal: true

module SmartRouting
  module Strategies
    # Стратегия 6: распределение по интенсивности и текущей загрузке.
    #
    # Здесь загрузка именно влияет на выбор, а не только проверяется на
    # достижение лимита: чем ближе провайдер к любому из своих потолков
    # (дневной оборот, in-progress, реквизиты, заявок в минуту),
    # тем ниже его балл.
    class LoadBalance < Base
      def self.key = 'load_balance'
      def self.title = 'Текущая загрузка'

      def score(candidates, operation, pool)
        at = operation.created_at || pool.now
        candidates.to_h do |candidate|
          load = [candidate.utilization, pool.rate_limiter.utilization(candidate, at)].max
          [candidate.name, clamp01(1.0 - load)]
        end
      end

      def explain(provider, operation, pool)
        at = operation.created_at || pool.now
        parts = {
          'дневной оборот' => provider.daily_utilization,
          'in-progress по количеству' => provider.in_progress_count_utilization,
          'in-progress по сумме' => provider.in_progress_amount_utilization,
          'реквизиты' => provider.requisites_utilization,
          'интенсивность' => pool.rate_limiter.utilization(provider, at)
        }
        worst = parts.max_by { |_, v| v }
        "загрузка #{pct(worst[1], 1.0)}% по узкому месту «#{worst[0]}»"
      end
    end
  end
end
