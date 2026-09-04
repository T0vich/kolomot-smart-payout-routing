# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Работать в минус нельзя, если это явно не разрешено соглашением.
    class Margin < Base
      def self.key = 'margin'

      def check(provider, _operation, _pool)
        return nil if provider.allow_negative_agreement?
        return nil if provider.provider_margin_pct <= provider.merchant_margin_pct

        reject_with('margin_negative',
             "provider_margin_pct #{provider.provider_margin_pct} > " \
             "merchant_margin_pct #{provider.merchant_margin_pct}, allow_negative_agreement отключён")
      end
    end
  end
end
