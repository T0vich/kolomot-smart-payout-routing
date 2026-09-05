# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'pipeline_test'

class ReportTest < Minitest::Test
  include TestHelper

  REQUIRED_KEYS = %w[
    period total_operations distribution skip_reasons projected_daily_utilization recommendations
  ].freeze

  def setup
    @decisions, @pool, @config, @calibrator = PipelineTest.run_pipeline
    @report = SmartRouting::Analytics::ReportBuilder.new(
      decisions: @decisions, pool: @pool, config: @config, calibrator: @calibrator
    ).build
  end

  def test_required_keys_from_specification
    REQUIRED_KEYS.each { |key| assert @report.key?(key), "в отчёте нет обязательного ключа #{key}" }
  end

  def test_report_is_serializable
    assert_kind_of String, JSON.pretty_generate(@report)
  end

  def test_total_matches_decisions
    assert_equal @decisions.size, @report['total_operations']
  end

  def test_distribution_shares_sum_to_hundred
    total = @report['distribution'].values.sum { |stat| stat['share_pct'] }
    assert_in_delta 100.0, total, 0.5
  end

  def test_distribution_reports_target_and_deviation
    @report['distribution'].each_value do |stat|
      %w[count share_pct target_pct deviation_pp volume volume_share_pct].each do |key|
        assert stat.key?(key), "в distribution нет #{key}"
      end
      assert_in_delta stat['share_pct'] - stat['target_pct'], stat['deviation_pp'], 0.01
    end
  end

  def test_counts_match_decisions
    @report['distribution'].each do |name, stat|
      expected = @decisions.count { |d| d.selected_provider == name }
      assert_equal expected, stat['count'], "неверное количество у #{name}"
    end
  end

  def test_results_section_covers_every_operation
    results = @report['results']
    assert_equal @decisions.size, results['approved'] + results['rejected'] + results['expired']
  end

  def test_skip_reasons_contain_only_hard_reasons
    @report['skip_reasons'].each_key do |reason|
      assert_includes SmartRouting::Models::Attempt::HARD_REASONS, reason
    end
  end

  def test_soft_skip_reasons_are_separated
    @report['soft_skip_reasons'].each_key do |reason|
      assert_includes SmartRouting::Models::Attempt::SOFT_REASONS, reason
    end
  end

  def test_utilization_never_exceeds_limits
    @report['projected_daily_utilization'].each do |name, stat|
      assert_operator stat['used'], :<=, stat['limit'], "#{name}: использовано больше лимита"
      assert_operator stat['utilization_pct'], :<=, 100.0
    end
  end

  def test_recommendations_are_actionable
    refute_empty @report['recommendations']
    @report['recommendations_detailed'].each do |item|
      assert item.key?('rule'), 'рекомендация должна называть правило'
      assert item.key?('parameter'), 'рекомендация должна называть параметр'
      refute_empty item['text'].to_s
    end
  end

  def test_deviation_causes_are_explained
    @report['deviations'].each do |item|
      refute_empty item['cause'].to_s, "#{item['provider']}: отклонение без объяснения причины"
    end
  end

  # Пустой deviations не должен читаться как «причины не считаются»:
  # отчёт обязан сказать, что существенных отклонений нет и почему.
  def test_deviations_note_explains_empty_list
    note = @report['deviations_note'].to_s
    refute_empty note, 'нет пояснения к deviations'
    if @report['deviations'].empty?
      assert_includes note, 'Существенных отклонений нет'
      worst = @report['distribution'].values.map { |s| s['deviation_pp'].abs }.max
      assert_includes note, worst.to_s
    else
      assert_includes note, SmartRouting::Analytics::ReportBuilder::SHARE_DEVIATION_ALERT_PP.to_s
    end
  end

  def test_deviations_note_is_absent_on_empty_queue
    config = SmartRouting::Config.load(nil, profile: 'balanced')
    providers = SmartRouting::Loaders.providers(File.join(TestHelper::DATA_DIR, 'providers.json'), config)
    pool = SmartRouting::ProviderPool.new(providers, config: config)
    report = SmartRouting::Analytics::ReportBuilder.new(
      decisions: [], pool: pool, config: config, period: '2026-07-30'
    ).build

    assert_nil report['deviations_note']
  end

  def test_history_calibration_is_included
    calibration = @report['history_calibration']
    refute_nil calibration
    assert_equal 100, calibration['operations']
    assert calibration['by_provider'].key?('vipay')
  end

  def test_report_without_history_still_builds
    report = SmartRouting::Analytics::ReportBuilder.new(
      decisions: @decisions, pool: @pool, config: @config, calibrator: nil
    ).build
    assert_nil report['history_calibration']
    REQUIRED_KEYS.each { |key| assert report.key?(key) }
  end

  def test_empty_queue_produces_valid_report
    config = SmartRouting::Config.load(nil, profile: 'balanced')
    providers = SmartRouting::Loaders.providers(File.join(TestHelper::DATA_DIR, 'providers.json'), config)
    pool = SmartRouting::ProviderPool.new(providers, config: config)
    report = SmartRouting::Analytics::ReportBuilder.new(
      decisions: [], pool: pool, config: config, period: '2026-07-30'
    ).build

    assert_equal 0, report['total_operations']
    REQUIRED_KEYS.each { |key| assert report.key?(key) }
  end
end
