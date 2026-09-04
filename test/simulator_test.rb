# frozen_string_literal: true

require_relative 'test_helper'

class SimulatorTest < Minitest::Test
  include TestHelper

  def test_outcome_is_deterministic_across_instances
    config = build_config
    provider = build_provider
    operation = build_operation

    first = SmartRouting::Simulator.new(config).outcome(operation, provider)
    second = SmartRouting::Simulator.new(config).outcome(operation, provider)
    assert_equal first, second
  end

  def test_seed_changes_result_distribution
    provider = build_provider('conversion_24h' => 0.5)
    operations = (1..40).map { |i| build_operation('operation_id' => "op_#{i}") }

    approved_with = lambda do |seed|
      simulator = SmartRouting::Simulator.new(build_config('simulation' => { 'seed' => seed }))
      operations.count { |op| simulator.outcome(op, provider).first == 'approved' }
    end

    refute_equal approved_with.call(1), approved_with.call(999)
  end

  def test_declines_disabled_by_default
    simulator = SmartRouting::Simulator.new(build_config)
    refute simulator.declines_enabled?
    40.times do |i|
      assert_equal :accepted, simulator.handoff(build_operation('operation_id' => "op_#{i}"), build_provider)
    end
  end

  def test_declines_can_be_enabled_by_profile
    config = build_config('simulation' => { 'seed' => 7, 'declines' => { 'enabled' => true, 'rate' => 1.0 } })
    simulator = SmartRouting::Simulator.new(config)
    assert simulator.declines_enabled?
    results = (1..10).map { |i| simulator.handoff(build_operation('operation_id' => "op_#{i}"), build_provider) }
    assert results.all? { |r| %i[declined timeout].include?(r) }
  end

  def test_outcome_respects_conversion_bounds
    always = SmartRouting::Simulator.new(build_config).outcome(build_operation, build_provider, conversion: 1.0)
    never = SmartRouting::Simulator.new(build_config).outcome(build_operation, build_provider, conversion: 0.0)
    assert_equal 'approved', always.first
    assert_includes %w[rejected expired], never.first
  end

  def test_latency_is_positive
    simulator = SmartRouting::Simulator.new(build_config)
    20.times do |i|
      _, latency = simulator.outcome(build_operation('operation_id' => "op_#{i}"), build_provider)
      assert_operator latency, :>, 0
    end
  end
end
