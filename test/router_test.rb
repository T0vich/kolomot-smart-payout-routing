# frozen_string_literal: true

require_relative 'test_helper'

# Симулятор с предсказуемым поведением: нужен, чтобы проверить каскад и
# fallback, не полагаясь на псевдослучайность.
class ScriptedSimulator
  def initialize(declines: [], result: 'approved', latency: 30)
    @declines = declines
    @result = result
    @latency = latency
  end

  def handoff(_operation, provider)
    @declines.include?(provider.name) ? :declined : :accepted
  end

  def outcome(_operation, _provider, conversion: nil)
    [@result, @latency]
  end
end

class RouterTest < Minitest::Test
  include TestHelper

  def providers
    [
      build_provider('payment_system' => 'alpha', 'traffic_percentage' => 60, 'priority' => 1),
      build_provider('payment_system' => 'beta', 'traffic_percentage' => 40, 'priority' => 2),
      build_provider({ 'payment_system' => 'spacepayments', 'traffic_percentage' => 0, 'priority' => 99,
                       'limit_amount_min' => nil, 'limit_amount_max' => nil, 'daily_amount_limit' => nil,
                       'in_progress_count_limit' => nil, 'in_progress_amount_limit' => nil },
                     { 'role' => 'fallback' })
    ]
  end

  def test_selects_from_eligible_pool
    router, = build_router(providers, build_config)
    decision = router.route(build_operation)

    assert_includes %w[alpha beta], decision.selected_provider
    refute decision.fallback_used
  end

  def test_every_considered_provider_appears_in_attempts
    router, = build_router(providers, build_config)
    decision = router.route(build_operation)

    names = decision.attempts.map(&:provider)
    assert_includes names, 'alpha'
    assert_includes names, 'beta'
    assert_equal 1, decision.attempts.count { |a| a.decision == 'selected' }
  end

  def test_hard_skip_carries_specific_reason
    list = providers
    list[0] = build_provider('payment_system' => 'alpha', 'banks' => %w[alfa], 'priority' => 1)
    router, = build_router(list, build_config)
    decision = router.route(build_operation('bank' => 'sberbank'))

    skipped = decision.attempts.find { |a| a.provider == 'alpha' }
    assert_equal 'bank_not_in_list', skipped.reason
    assert_includes skipped.details, 'sberbank'
  end

  def test_cascade_moves_to_next_provider_on_decline
    router, = build_router(providers, build_config, simulator: ScriptedSimulator.new(declines: %w[alpha]))
    decision = router.route(build_operation)

    assert_equal 'beta', decision.selected_provider
    declined = decision.attempts.find { |a| a.provider == 'alpha' }
    assert_equal 'provider_declined', declined.reason
  end

  def test_falls_back_to_self_provider_when_all_decline
    router, = build_router(providers, build_config, simulator: ScriptedSimulator.new(declines: %w[alpha beta]))
    decision = router.route(build_operation)

    assert_equal 'spacepayments', decision.selected_provider
    assert decision.fallback_used
    assert_equal 'fallback_self_provider', decision.attempts.last.reason
  end

  def test_falls_back_when_pool_is_empty_by_hard_constraints
    list = providers
    list[0] = build_provider('payment_system' => 'alpha', 'limit_amount_max' => 1_000, 'priority' => 1)
    list[1] = build_provider('payment_system' => 'beta', 'limit_amount_max' => 1_000, 'priority' => 2)
    router, = build_router(list, build_config)
    decision = router.route(build_operation('amount' => 90_000))

    assert_equal 'spacepayments', decision.selected_provider
    assert decision.fallback_used
  end

  def test_only_eligible_provider_reason
    list = providers
    list[1] = build_provider('payment_system' => 'beta', 'banks' => %w[alfa], 'priority' => 2)
    router, = build_router(list, build_config)
    decision = router.route(build_operation('bank' => 'sberbank'))

    selected = decision.attempts.find { |a| a.decision == 'selected' }
    assert_equal 'only_eligible_provider', selected.reason
  end

  def test_state_is_updated_after_each_operation
    router, pool = build_router(providers, build_config, simulator: ScriptedSimulator.new(latency: 3600))
    router.route(build_operation('operation_id' => 'op_1', 'amount' => 10_000))

    alpha = pool['alpha']
    beta = pool['beta']
    busy = [alpha, beta].find { |p| p.routed_count.positive? }

    assert_equal 1, busy.routed_count
    assert_equal 10_000, busy.routed_amount
    assert_equal 1, busy.in_progress_count, 'заявка должна занимать слот, пока не завершилась'
    assert_equal 10_000, busy.daily_reserved_amount
  end

  def test_in_progress_is_released_when_operation_finishes
    router, pool = build_router(providers, build_config, simulator: ScriptedSimulator.new(latency: 10))
    router.route(build_operation('operation_id' => 'op_1', 'created_at' => '2026-07-30T09:00:00+03:00'))
    router.route(build_operation('operation_id' => 'op_2', 'created_at' => '2026-07-30T09:05:00+03:00'))

    finished = pool['alpha'].in_progress_count + pool['beta'].in_progress_count
    assert_equal 1, finished, 'первая заявка должна освободить слот до второй'
  end

  def test_respects_max_attempts
    config = build_config('max_attempts' => 1)
    router, = build_router(providers, config, simulator: ScriptedSimulator.new(declines: %w[alpha]))
    decision = router.route(build_operation)

    assert_equal 'spacepayments', decision.selected_provider,
                 'при max_attempts=1 второй кандидат не пробуется'
  end

  def test_raises_when_nothing_can_take_operation
    list = providers.first(2)
    list[0] = build_provider('payment_system' => 'alpha', 'status' => 'disabled')
    list[1] = build_provider('payment_system' => 'beta', 'status' => 'disabled')
    router, = build_router(list, build_config)

    assert_raises(SmartRouting::NoProviderError) { router.route(build_operation) }
  end

  def test_distribution_follows_traffic_targets
    # Лимиты специально сняты: тест проверяет только математику целевых долей.
    roomy = [
      build_provider('payment_system' => 'alpha', 'traffic_percentage' => 60, 'priority' => 1,
                     'available_requisites' => 100, 'in_progress_count_limit' => nil),
      build_provider('payment_system' => 'beta', 'traffic_percentage' => 40, 'priority' => 2,
                     'available_requisites' => 100, 'in_progress_count_limit' => nil)
    ]
    router, = build_router(roomy, build_config('weights' => { 'traffic_share' => 1.0 }))
    decisions = router.route_all(
      (1..10).map { |i| build_operation('operation_id' => "op_#{i}", 'amount' => 10_000) }
    )
    counts = decisions.group_by(&:selected_provider).transform_values(&:size)

    assert_equal 6, counts['alpha'], 'цель 60% по количеству'
    assert_equal 4, counts['beta'], 'цель 40% по количеству'
  end

  def test_provider_leaves_pool_when_requisites_run_out
    list = providers
    list[0] = build_provider('payment_system' => 'alpha', 'available_requisites' => 1, 'priority' => 1)
    router, = build_router(list, build_config, simulator: ScriptedSimulator.new(latency: 3600))

    first = router.route(build_operation('operation_id' => 'op_1'))
    second = router.route(build_operation('operation_id' => 'op_2'))
    third = router.route(build_operation('operation_id' => 'op_3'))

    assert_includes [first, second, third].map(&:selected_provider), 'beta'
    exhausted = [first, second, third].flat_map(&:attempts)
                                     .find { |a| a.provider == 'alpha' && a.reason == 'no_available_requisites' }
    refute_nil exhausted, 'после исчерпания реквизитов провайдер должен отсеиваться с явной причиной'
  end
end
