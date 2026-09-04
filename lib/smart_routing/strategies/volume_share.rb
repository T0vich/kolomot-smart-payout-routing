# frozen_string_literal: true

module SmartRouting
  module Strategies
    # Стратегия 2: процент от объёма (volume_share_pct).
    #
    # Та же математика, что и в TrafficShare, но доли считаются в рублях.
    # Именно поэтому крупная заявка сильнее двигает распределение, чем мелкая.
    class VolumeShare < Base
      def self.key = 'volume_share'
      def self.title = 'Доля по объёму'

      def score(candidates, operation, pool)
        errors = candidates.to_h do |candidate|
          [candidate.name, pool.share_error_after(:volume, candidate, operation.amount)]
        end
        contrast_inverse(errors)
      end

      def explain(provider, _operation, pool)
        actual = pct(pool.share(:volume, provider.name), 1.0)
        target = provider.volume_share_pct
        delta = round2(actual - target)
        direction = delta.negative? ? 'недобирает' : 'перебирает'
        "доля по объёму #{actual}% при цели #{target}% (#{direction} #{delta.abs} п.п.)"
      end
    end
  end
end
