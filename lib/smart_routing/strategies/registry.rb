# frozen_string_literal: true

module SmartRouting
  module Strategies
    # Реестр мягких целей.
    #
    # Новая стратегия = класс-наследник Base + строка здесь + вес в конфиге.
    # Ядро роутера про конкретные стратегии ничего не знает.
    module Registry
      ALL = [
        TrafficShare,
        VolumeShare,
        CascadePriority,
        AmountBand,
        Conversion,
        LoadBalance,
        TurnoverCommitment
      ].freeze

      module_function

      def keys = ALL.map(&:key)

      def find(key)
        ALL.find { |klass| klass.key == key }
      end

      # Собирает только те стратегии, у которых в профиле положительный вес.
      def build(config, observed_conversion: {})
        config.weights.keys.map do |key|
          klass = find(key)
          raise ConfigError, "Неизвестная стратегия: #{key}" if klass.nil?

          if klass == Conversion
            klass.new(config, observed: observed_conversion)
          else
            klass.new(config)
          end
        end
      end
    end
  end
end
