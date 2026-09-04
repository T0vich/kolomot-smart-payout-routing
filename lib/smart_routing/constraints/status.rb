# frozen_string_literal: true

module SmartRouting
  module Constraints
    # Провайдер должен быть активен.
    class Status < Base
      def self.key = 'status'

      def check(provider, _operation, _pool)
        return nil if provider.active?

        reject_with('provider_inactive', "status #{provider.status.inspect}, ожидается \"active\"")
      end
    end
  end
end
