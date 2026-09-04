# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Без свободных реквизитов принять выплату физически некуда.
    class Requisites < Base
      def self.key = 'requisites'

      def check(provider, _operation, _pool)
        return nil if provider.available_requisites.positive?

        reject_with('no_available_requisites', 'available_requisites == 0')
      end
    end
  end
end
