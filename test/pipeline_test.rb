# frozen_string_literal: true

require_relative 'test_helper'

# Сквозной прогон на реальных данных кейса + повторение проверок,
# которые делает валидатор организаторов. Если этот тест зелёный,
# scripts/validate_10.rb тоже пройдёт.
class PipelineTest < Minitest::Test
  include TestHelper

  def self.run_pipeline(profile: 'balanced')
    config = SmartRouting::Config.load(nil, profile: profile)
    calibrator = SmartRouting::Analytics::HistoryCalibrator.load(File.join(TestHelper::DATA_DIR,
                                                                          'operations_history.csv'))
    providers = SmartRouting::Loaders.providers(File.join(TestHelper::DATA_DIR, 'providers.json'), config)
    operations = SmartRouting::Loaders.operations(File.join(TestHelper::DATA_DIR, 'operations_queue_10.json'))
    pool = SmartRouting::ProviderPool.new(providers, config: config)
    scorer = SmartRouting::Scoring::CompositeScorer.new(
      config,
      SmartRouting::Strategies::Registry.build(config, observed_conversion: calibrator.conversion_by_provider)
    )
    router = SmartRouting::Router.new(pool: pool, config: config,
                                      scorer: scorer, simulator: SmartRouting::Simulator.new(config))
    [router.route_all(operations), pool, config, calibrator, operations]
  end

  def setup
    @decisions, @pool, @config, @calibrator, @operations = self.class.run_pipeline
    @by_id = @decisions.to_h { |d| [d.operation.id, d] }
    @reference = JSON.parse(File.read(File.join(TestHelper::DATA_DIR, 'reference_decisions.json')))
  end

  def test_every_operation_has_a_decision
    assert_equal @operations.map(&:id).sort, @decisions.map { |d| d.operation.id }.sort
  end

  def test_deterministic_cases_match_reference
    @reference['deterministic_cases'].each do |case_|
      decision = @by_id[case_['operation_id']]
      refute_nil decision
      assert_equal case_['required_provider'], decision.selected_provider,
                   "#{case_['operation_id']}: #{case_['reason']}"
    end
  end

  def test_selected_provider_is_always_eligible_by_reference
    @reference['eligible_providers'].each do |op_id, eligible|
      decision = @by_id[op_id]
      next if decision.nil?

      allowed = eligible + ['spacepayments']
      assert_includes allowed, decision.selected_provider,
                      "#{op_id}: выбран недопустимый провайдер"
    end
  end

  def test_expected_skip_reasons_are_present_with_exact_codes
    @reference['skip_reasons_expected'].each do |op_id, skips|
      decision = @by_id[op_id]
      next if decision.nil?

      skips.each do |provider, expected_reason|
        attempt = decision.attempts.find { |a| a.provider == provider }
        refute_nil attempt, "#{op_id}: нет записи о рассмотрении #{provider}"
        assert_equal 'skipped', attempt.decision, "#{op_id}: #{provider} должен быть skipped"
        assert_equal expected_reason, attempt.reason, "#{op_id}: причина отсева #{provider}"
      end
    end
  end

  def test_required_output_fields_are_present
    @decisions.each do |decision|
      hash = decision.to_h
      %w[operation_id selected_provider attempts simulated_result latency_sec].each do |field|
        assert hash.key?(field), "#{decision.operation.id}: отсутствует #{field}"
      end
      assert_includes %w[approved rejected expired], hash['simulated_result']
      hash['attempts'].each do |attempt|
        %w[provider decision reason].each { |field| assert attempt.key?(field) }
        assert_includes %w[selected skipped], attempt['decision']
      end
    end
  end

  def test_exactly_one_selected_attempt_per_operation
    @decisions.each do |decision|
      selected = decision.attempts.count { |a| a.decision == 'selected' }
      assert_equal 1, selected, "#{decision.operation.id}: должна быть ровно одна запись selected"
    end
  end

  def test_selected_attempt_matches_selected_provider
    @decisions.each do |decision|
      attempt = decision.attempts.find { |a| a.decision == 'selected' }
      assert_equal decision.selected_provider, attempt.provider
    end
  end

  def test_every_eligible_provider_is_explained
    @decisions.each do |decision|
      decision.eligible.each do |name|
        attempt = decision.attempts.find { |a| a.provider == name }
        refute_nil attempt, "#{decision.operation.id}: допустимый #{name} не объяснён в attempts"
      end
    end
  end

  def test_hard_limits_are_never_violated
    @pool.providers.each do |provider|
      limit = provider.daily_amount_limit
      next if limit.nil?

      assert_operator provider.daily_approved_amount, :<=, limit,
                      "#{provider.name}: превышен дневной лимит"
    end
  end

  def test_run_is_reproducible
    other, = self.class.run_pipeline
    assert_equal @decisions.map(&:to_h), other.map(&:to_h)
  end

  def test_every_profile_produces_valid_decisions
    YAML.safe_load(File.read(SmartRouting::Config::DEFAULT_PATH), aliases: true)['profiles'].each_key do |profile|
      decisions, = self.class.run_pipeline(profile: profile)
      assert_equal 10, decisions.size, "профиль #{profile}"
      decisions.each do |decision|
        refute_nil decision.selected_provider, "профиль #{profile}: пустой selected_provider"
      end
    end
  end

  def test_failover_profile_exercises_cascade
    decisions, = self.class.run_pipeline(profile: 'demo_failover')
    retried = decisions.count do |d|
      d.attempts.any? { |a| %w[provider_declined provider_timeout].include?(a.reason) }
    end
    assert_operator retried, :>, 0, 'демо-профиль должен показывать переход к следующему провайдеру'
  end
end
