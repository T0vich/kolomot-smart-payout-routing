# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/smart_routing'

module TestHelper
  DATA_DIR = File.join(SmartRouting::ROOT, 'data')

  PROVIDER_TEMPLATE = {
    'payment_system' => 'test',
    'status' => 'active',
    'traffic_percentage' => 50,
    'priority' => 1,
    'limit_amount_min' => 1000,
    'limit_amount_max' => 100_000,
    'daily_amount_limit' => 1_000_000,
    'daily_approved_amount' => 0,
    'in_progress_count_limit' => 10,
    'in_progress_count' => 0,
    'in_progress_amount_limit' => 500_000,
    'in_progress_amount' => 0,
    'available_requisites' => 5,
    'conversion_24h' => 0.9,
    'avg_latency_sec' => 30,
    'banks' => [],
    'exclude_banks' => false,
    'provider_margin_pct' => 1.0,
    'merchant_margin_pct' => 1.5,
    'allow_negative_agreement' => false
  }.freeze

  def build_provider(overrides = {}, extension = {})
    SmartRouting::Models::Provider.new(PROVIDER_TEMPLATE.merge(stringify(overrides)), extension: stringify(extension))
  end

  def build_operation(overrides = {})
    defaults = {
      'operation_id' => 'op_test',
      'created_at' => '2026-07-30T09:00:00+03:00',
      'amount' => 10_000,
      'bank' => 'sberbank'
    }
    SmartRouting::Models::Operation.new(defaults.merge(stringify(overrides)))
  end

  def build_config(profile_overrides = {}, profile_name = 'test')
    raw = {
      'active_profile' => profile_name,
      'defaults' => {
        'fallback_provider' => 'spacepayments',
        'max_attempts' => 3,
        'tie_break_epsilon' => 0.02,
        'conflict_order' => %w[turnover_commitment traffic_share conversion],
        'history_blend' => 0.0,
        'constraints' => {
          'status' => { 'enabled' => true },
          'amount_range' => { 'enabled' => true },
          'bank_filter' => { 'enabled' => true },
          'daily_amount_limit' => { 'enabled' => true },
          'turnover_max' => { 'enabled' => true },
          'in_progress' => { 'enabled' => true },
          'requisites' => { 'enabled' => true },
          'margin' => { 'enabled' => true },
          'rate_limit' => { 'enabled' => true }
        },
        'provider_defaults' => {},
        'provider_overrides' => {},
        'amount_bands' => [],
        'simulation' => { 'seed' => 1, 'declines' => { 'enabled' => false } }
      },
      'profiles' => {
        profile_name => { 'weights' => { 'traffic_share' => 1.0 } }.merge(stringify(profile_overrides))
      }
    }
    SmartRouting::Config.new(raw, profile: profile_name)
  end

  def build_pool(providers, config)
    SmartRouting::ProviderPool.new(providers, config: config)
  end

  def build_router(providers, config, simulator: nil)
    pool = build_pool(providers, config)
    scorer = SmartRouting::Scoring::CompositeScorer.new(config, SmartRouting::Strategies::Registry.build(config))
    router = SmartRouting::Router.new(
      pool: pool, config: config, scorer: scorer,
      simulator: simulator || SmartRouting::Simulator.new(config)
    )
    [router, pool]
  end

  def stringify(hash)
    hash.to_h { |k, v| [k.to_s, v] }
  end
end
