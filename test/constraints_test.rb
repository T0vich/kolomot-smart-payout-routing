# frozen_string_literal: true

require_relative 'test_helper'

class ConstraintsTest < Minitest::Test
  include TestHelper

  def setup
    @config = build_config
    @chain = SmartRouting::Constraints::Chain.new(SmartRouting::Constraints::Registry.build(@config))
  end

  def check(provider, operation, pool = nil)
    @chain.check(provider, operation, pool || build_pool([provider], @config))
  end

  def test_active_provider_passes
    assert_nil check(build_provider, build_operation)
  end

  def test_inactive_provider_rejected
    verdict = check(build_provider('status' => 'disabled'), build_operation)
    assert_equal 'provider_inactive', verdict.reason
  end

  def test_amount_below_minimum
    verdict = check(build_provider('limit_amount_min' => 5000), build_operation('amount' => 800))
    assert_equal 'amount_below_minimum', verdict.reason
    assert_includes verdict.details, '800'
  end

  def test_amount_above_maximum
    verdict = check(build_provider('limit_amount_max' => 50_000), build_operation('amount' => 150_000))
    assert_equal 'amount_exceeds_limit', verdict.reason
  end

  def test_nil_amount_limits_are_open
    provider = build_provider('limit_amount_min' => nil, 'limit_amount_max' => nil,
                              'daily_amount_limit' => nil, 'in_progress_amount_limit' => nil)
    assert_nil check(provider, build_operation('amount' => 10_000_000))
  end

  def test_bank_whitelist
    provider = build_provider('banks' => %w[sberbank alfa])
    assert_nil check(provider, build_operation('bank' => 'alfa'))
    verdict = check(provider, build_operation('bank' => 'tinkoff'))
    assert_equal 'bank_not_in_list', verdict.reason
  end

  def test_bank_blacklist
    provider = build_provider('banks' => %w[tinkoff], 'exclude_banks' => true)
    assert_nil check(provider, build_operation('bank' => 'sberbank'))
    verdict = check(provider, build_operation('bank' => 'tinkoff'))
    assert_equal 'bank_in_exclude_list', verdict.reason
  end

  def test_empty_bank_list_accepts_everything
    assert_nil check(build_provider('banks' => []), build_operation('bank' => 'unknown_bank'))
  end

  def test_daily_limit_counts_reserved_amount
    provider = build_provider('daily_amount_limit' => 100_000, 'daily_approved_amount' => 90_000)
    assert_nil check(provider, build_operation('amount' => 10_000))

    provider.daily_reserved_amount = 5_000
    verdict = check(provider, build_operation('amount' => 10_000))
    assert_equal 'daily_limit_exceeded', verdict.reason
  end

  def test_in_progress_count_limit
    provider = build_provider('in_progress_count_limit' => 2, 'in_progress_count' => 2)
    verdict = check(provider, build_operation)
    assert_equal 'in_progress_count_limit', verdict.reason
  end

  def test_in_progress_amount_limit
    provider = build_provider('in_progress_amount_limit' => 15_000, 'in_progress_amount' => 10_000)
    verdict = check(provider, build_operation('amount' => 10_000))
    assert_equal 'in_progress_amount_limit', verdict.reason
  end

  def test_no_requisites
    verdict = check(build_provider('available_requisites' => 0), build_operation)
    assert_equal 'no_available_requisites', verdict.reason
  end

  def test_negative_margin_blocked_unless_allowed
    provider = build_provider('provider_margin_pct' => 2.0, 'merchant_margin_pct' => 1.5)
    assert_equal 'margin_negative', check(provider, build_operation).reason

    allowed = build_provider('provider_margin_pct' => 2.0, 'merchant_margin_pct' => 1.5,
                             'allow_negative_agreement' => true)
    assert_nil check(allowed, build_operation)
  end

  def test_turnover_max_is_separate_from_daily_limit
    provider = build_provider({ 'daily_amount_limit' => 1_000_000, 'daily_approved_amount' => 200_000 },
                              { 'daily_turnover_max' => 205_000 })
    verdict = check(provider, build_operation('amount' => 10_000))
    assert_equal 'daily_turnover_max_reached', verdict.reason
  end

  def test_rate_limit_uses_sliding_window
    provider = build_provider({}, { 'requests_per_minute_limit' => 2 })
    pool = build_pool([provider], @config)
    at = Time.parse('2026-07-30T09:00:00+03:00')
    2.times { pool.rate_limiter.record(provider.name, at) }

    verdict = check(provider, build_operation('created_at' => at.iso8601), pool)
    assert_equal 'rate_limit_exceeded', verdict.reason

    later = build_operation('created_at' => (at + 61).iso8601)
    assert_nil check(provider, later, pool)
  end

  def test_disabled_constraint_is_not_applied
    config = build_config('constraints' => { 'bank_filter' => { 'enabled' => false } })
    chain = SmartRouting::Constraints::Chain.new(SmartRouting::Constraints::Registry.build(config))
    provider = build_provider('banks' => %w[sberbank])
    assert_nil chain.check(provider, build_operation('bank' => 'tinkoff'), build_pool([provider], config))
  end

  # Валидатор организаторов исключает провайдера с нулевой долей трафика
  # (кроме self-provider) — у нас это должно быть таким же hard-constraint.
  def test_zero_traffic_provider_is_rejected
    constraint = SmartRouting::Constraints::TrafficEnabled.new
    provider = build_provider('payment_system' => 'newpay', 'traffic_percentage' => 0)

    verdict = constraint.check(provider, build_operation, nil)

    refute_nil verdict
    assert_equal 'traffic_share_disabled', verdict.reason
  end

  def test_zero_traffic_self_provider_is_allowed
    constraint = SmartRouting::Constraints::TrafficEnabled.new
    provider = build_provider({ 'payment_system' => 'spacepayments', 'traffic_percentage' => 0 },
                              { 'role' => 'fallback' })

    assert_nil constraint.check(provider, build_operation, nil)
  end

  def test_positive_traffic_provider_is_allowed
    constraint = SmartRouting::Constraints::TrafficEnabled.new

    assert_nil constraint.check(build_provider('traffic_percentage' => 25), build_operation, nil)
  end
end
