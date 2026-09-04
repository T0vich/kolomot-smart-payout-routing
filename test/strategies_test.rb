# frozen_string_literal: true

require_relative 'test_helper'

class StrategiesTest < Minitest::Test
  include TestHelper

  def setup
    @config = build_config
    @a = build_provider('payment_system' => 'alpha', 'traffic_percentage' => 70, 'priority' => 1,
                        'conversion_24h' => 0.9)
    @b = build_provider('payment_system' => 'beta', 'traffic_percentage' => 30, 'priority' => 2,
                        'conversion_24h' => 0.6)
    @candidates = [@a, @b]
    @pool = build_pool(@candidates, @config)
  end

  def test_traffic_share_prefers_starved_provider
    strategy = SmartRouting::Strategies::TrafficShare.new(@config)
    @pool.occupy(@a, build_operation, 10, 'approved')

    scores = strategy.score(@candidates, build_operation, @pool)
    assert_operator scores['beta'], :>, scores['alpha'],
                    'провайдер с недобранной долей должен получать больший балл'
  end

  def test_traffic_share_returns_normalized_values
    strategy = SmartRouting::Strategies::TrafficShare.new(@config)
    scores = strategy.score(@candidates, build_operation, @pool)
    scores.each_value { |value| assert_includes 0.0..1.0, value }
  end

  def test_volume_share_reacts_to_amount_not_count
    strategy = SmartRouting::Strategies::VolumeShare.new(@config)
    @pool.occupy(@a, build_operation('amount' => 100_000), 10, 'approved')

    scores = strategy.score(@candidates, build_operation('amount' => 1_000), @pool)
    assert_operator scores['beta'], :>, scores['alpha']
  end

  def test_cascade_priority_ranks_by_priority
    strategy = SmartRouting::Strategies::CascadePriority.new(@config)
    scores = strategy.score(@candidates, build_operation, @pool)
    assert_equal 1.0, scores['alpha']
    assert_equal 0.0, scores['beta']
  end

  def test_cascade_priority_with_single_candidate
    strategy = SmartRouting::Strategies::CascadePriority.new(@config)
    assert_equal({ 'alpha' => 1.0 }, strategy.score([@a], build_operation, @pool))
  end

  def test_conversion_prefers_higher_rate
    strategy = SmartRouting::Strategies::Conversion.new(@config)
    scores = strategy.score(@candidates, build_operation, @pool)
    assert_equal 1.0, scores['alpha']
    assert_equal 0.0, scores['beta']
  end

  def test_conversion_blends_history
    config = build_config('history_blend' => 1.0)
    strategy = SmartRouting::Strategies::Conversion.new(config, observed: { 'alpha' => 0.1, 'beta' => 0.95 })
    scores = strategy.score(@candidates, build_operation, @pool)
    assert_operator scores['beta'], :>, scores['alpha'],
                    'при history_blend=1 должна побеждать фактическая конверсия'
  end

  def test_amount_band_prefers_configured_provider
    config = build_config('amount_bands' => [{ 'from' => 0, 'to' => 50_000, 'prefer' => ['beta'] }])
    strategy = SmartRouting::Strategies::AmountBand.new(config)
    scores = strategy.score(@candidates, build_operation('amount' => 10_000), @pool)
    assert_equal 1.0, scores['beta']
    assert_equal 0.25, scores['alpha']
  end

  def test_amount_band_is_neutral_outside_configured_ranges
    config = build_config('amount_bands' => [{ 'from' => 0, 'to' => 100, 'prefer' => ['beta'] }])
    strategy = SmartRouting::Strategies::AmountBand.new(config)
    scores = strategy.score(@candidates, build_operation('amount' => 50_000), @pool)
    assert_equal 0.5, scores['beta']
    assert_equal 0.5, scores['alpha']
  end

  def test_load_balance_penalizes_loaded_provider
    loaded = build_provider('payment_system' => 'alpha', 'daily_amount_limit' => 100_000,
                            'daily_approved_amount' => 95_000)
    idle = build_provider('payment_system' => 'beta', 'daily_amount_limit' => 100_000,
                          'daily_approved_amount' => 0)
    pool = build_pool([loaded, idle], @config)
    strategy = SmartRouting::Strategies::LoadBalance.new(@config)
    scores = strategy.score([loaded, idle], build_operation, pool)
    assert_operator scores['beta'], :>, scores['alpha']
  end

  def test_turnover_commitment_boosts_unmet_minimum
    hungry = build_provider({ 'payment_system' => 'alpha' }, { 'daily_turnover_min' => 1_000_000 })
    satisfied = build_provider({ 'payment_system' => 'beta', 'daily_approved_amount' => 900_000 },
                               { 'daily_turnover_max' => 1_000_000 })
    pool = build_pool([hungry, satisfied], @config)
    strategy = SmartRouting::Strategies::TurnoverCommitment.new(@config)
    scores = strategy.score([hungry, satisfied], build_operation, pool)

    assert_operator scores['alpha'], :>=, 0.6, 'непокрытое обязательство должно поднимать провайдера'
    assert_operator scores['beta'], :<, 0.5, 'близость к потолку оборота должна опускать провайдера'
  end

  def test_registry_builds_only_weighted_strategies
    config = build_config('weights' => { 'traffic_share' => 0.5, 'conversion' => 0.5 })
    keys = SmartRouting::Strategies::Registry.build(config).map(&:key)
    assert_equal %w[traffic_share conversion].sort, keys.sort
  end
end
