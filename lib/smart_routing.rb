# frozen_string_literal: true

require 'json'
require 'yaml'
require 'time'
require 'digest'

# Умный роутинг выплат между платёжными провайдерами.
#
# Пайплайн одной операции:
#   ProviderPool#advance_clock -> Constraints (hard) -> Strategies (soft)
#   -> Scoring::CompositeScorer -> Router (каскад попыток + fallback)
#   -> Simulator (исход) -> ProviderPool#apply (обновление состояния)
module SmartRouting
  ROOT = File.expand_path('..', __dir__)
end

require_relative 'smart_routing/version'
require_relative 'smart_routing/errors'
require_relative 'smart_routing/support/numeric'
require_relative 'smart_routing/support/csv_reader'
require_relative 'smart_routing/config'
require_relative 'smart_routing/models/operation'
require_relative 'smart_routing/models/provider'
require_relative 'smart_routing/models/attempt'
require_relative 'smart_routing/models/decision'
require_relative 'smart_routing/rate_limiter'
require_relative 'smart_routing/provider_pool'
require_relative 'smart_routing/constraints/base'
require_relative 'smart_routing/constraints/status'
require_relative 'smart_routing/constraints/traffic_enabled'
require_relative 'smart_routing/constraints/amount_range'
require_relative 'smart_routing/constraints/daily_amount_limit'
require_relative 'smart_routing/constraints/in_progress'
require_relative 'smart_routing/constraints/bank_filter'
require_relative 'smart_routing/constraints/margin'
require_relative 'smart_routing/constraints/requisites'
require_relative 'smart_routing/constraints/rate_limit'
require_relative 'smart_routing/constraints/turnover_max'
require_relative 'smart_routing/constraints/registry'
require_relative 'smart_routing/strategies/base'
require_relative 'smart_routing/strategies/traffic_share'
require_relative 'smart_routing/strategies/volume_share'
require_relative 'smart_routing/strategies/cascade_priority'
require_relative 'smart_routing/strategies/amount_band'
require_relative 'smart_routing/strategies/conversion'
require_relative 'smart_routing/strategies/load_balance'
require_relative 'smart_routing/strategies/turnover_commitment'
require_relative 'smart_routing/strategies/registry'
require_relative 'smart_routing/scoring/score_card'
require_relative 'smart_routing/scoring/composite_scorer'
require_relative 'smart_routing/simulator'
require_relative 'smart_routing/router'
require_relative 'smart_routing/analytics/history_calibrator'
require_relative 'smart_routing/analytics/report_builder'
require_relative 'smart_routing/analytics/backtest'
require_relative 'smart_routing/analytics/profile_comparison'
require_relative 'smart_routing/analytics/dashboard'
require_relative 'smart_routing/loaders'
require_relative 'smart_routing/cli'
