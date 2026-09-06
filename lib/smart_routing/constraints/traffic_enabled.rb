# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Провайдер с нулевой долей трафика выключен из распределения.
    #
    # Валидатор организаторов исключает такого провайдера из допустимых:
    #   next false if p['traffic_percentage'].to_f.zero? && p['payment_system'] != 'spacepayments'
    #
    # Self-provider живёт вне долей — у него ноль по определению, и это не запрет.
    class TrafficEnabled < Base
      def self.key = 'traffic_enabled'

      def check(provider, _operation, _pool)
        return nil if provider.fallback_role?
        return nil unless provider.traffic_percentage.zero?

        reject_with('traffic_share_disabled',
                    'traffic_percentage == 0: провайдер выключен из распределения трафика')
      end
    end
  end
end
