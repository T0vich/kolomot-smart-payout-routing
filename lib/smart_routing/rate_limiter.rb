# frozen_string_literal: true

module SmartRouting
  # Скользящее окно на 60 секунд: сколько заявок провайдер уже принял.
  #
  # Нужен и как hard-constraint (стратегия 6 «по интенсивности»),
  # и как soft-сигнал загрузки в Strategies::LoadBalance.
  class RateLimiter
    WINDOW_SEC = 60

    def initialize
      @hits = Hash.new { |h, k| h[k] = [] }
    end

    def record(provider_name, time)
      return if time.nil?

      @hits[provider_name] << time
    end

    def count_in_window(provider_name, time)
      return 0 if time.nil?

      prune(provider_name, time)
      @hits[provider_name].size
    end

    # Доля выбранного лимита интенсивности в [0, 1].
    def utilization(provider, time)
      limit = provider.requests_per_minute_limit
      return 0.0 if limit.nil? || limit <= 0

      Support::Numeric.clamp01(count_in_window(provider.name, time).to_f / limit)
    end

    def exceeded?(provider, time)
      limit = provider.requests_per_minute_limit
      return false if limit.nil? || limit <= 0 || time.nil?

      count_in_window(provider.name, time) + 1 > limit
    end

    private

    def prune(provider_name, time)
      threshold = time - WINDOW_SEC
      @hits[provider_name].reject! { |t| t <= threshold }
    end
  end
end
