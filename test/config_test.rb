# frozen_string_literal: true

require_relative 'test_helper'

class ConfigTest < Minitest::Test
  include TestHelper

  def test_real_config_loads_every_profile
    raw = YAML.safe_load(File.read(SmartRouting::Config::DEFAULT_PATH), aliases: true)
    raw['profiles'].each_key do |name|
      config = SmartRouting::Config.load(nil, profile: name)
      refute_empty config.weights, "профиль #{name} должен иметь веса"
    end
  end

  def test_unknown_profile_raises
    error = assert_raises(SmartRouting::ConfigError) { SmartRouting::Config.load(nil, profile: 'нет-такого') }
    assert_includes error.message, 'нет-такого'
  end

  def test_unknown_strategy_raises
    error = assert_raises(SmartRouting::ConfigError) { build_config('weights' => { 'магия' => 1.0 }) }
    assert_includes error.message, 'магия'
  end

  def test_empty_weights_raise
    error = assert_raises(SmartRouting::ConfigError) { build_config('weights' => {}) }
    assert_includes error.message, 'weights'
  end

  def test_unknown_constraint_raises
    assert_raises(SmartRouting::ConfigError) do
      build_config('constraints' => { 'телепатия' => { 'enabled' => true } })
    end
  end

  def test_profile_overrides_defaults_deeply
    config = SmartRouting::Config.load(nil, profile: 'demo_failover')
    assert config.simulation.dig('declines', 'enabled'), 'демо-профиль включает отказы'

    default = SmartRouting::Config.load(nil, profile: 'balanced')
    refute default.simulation.dig('declines', 'enabled'), 'сдаваемый профиль отказы не симулирует'
  end

  def test_provider_extension_merges_defaults_and_overrides
    config = SmartRouting::Config.load(nil, profile: 'balanced')
    extension = config.provider_extension('payflow')
    assert_equal 7, extension['requests_per_minute_limit']
    assert_equal 2_000_000, extension['daily_turnover_min']
  end

  def test_conflict_order_is_validated
    assert_raises(SmartRouting::ConfigError) { build_config('conflict_order' => %w[несуществующая]) }
  end

  def test_missing_config_file_raises
    assert_raises(SmartRouting::InputError) { SmartRouting::Config.load('нет-такого.yml') }
  end
end
