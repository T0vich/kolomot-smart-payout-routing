# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Ограничение интенсивности: не больше N заявок в минуту на провайдера.
    #
    # Стратегия 6 из ТЗ в жёсткой её части. Мягкая часть — учёт текущей
    # загрузки при выборе — живёт в Strategies::LoadBalance.
    class RateLimit < Base
      def self.key = 'rate_limit'

      def check(provider, operation, pool)
        limit = provider.requests_per_minute_limit
        return nil if limit.nil? || limit <= 0

        at = operation.created_at || pool.now
        return nil unless pool.rate_limiter.exceeded?(provider, at)

        used = pool.rate_limiter.count_in_window(provider.name, at)
        reject_with('rate_limit_exceeded', "#{used} заявок за последние 60 сек, requests_per_minute_limit #{limit}")
      end
    end
  end
end
