# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'pipeline_test'

class AnalyticsTest < Minitest::Test
  include TestHelper

  def history_path = File.join(TestHelper::DATA_DIR, 'operations_history.csv')
  def providers_path = File.join(TestHelper::DATA_DIR, 'providers.json')
  def queue_path = File.join(TestHelper::DATA_DIR, 'operations_queue_10.json')

  # --- CSV ---

  def test_csv_reader_parses_history
    rows = SmartRouting::Support::CsvReader.read(history_path)
    assert_equal 100, rows.size
    assert_equal 'op_001', rows.first['operation_id']
    assert_equal 'vipay', rows.first['payment_system']
  end

  def test_csv_reader_handles_quotes_and_embedded_commas
    rows = SmartRouting::Support::CsvReader.parse(%(a,b\n"1,5","он сказал ""да"""\n))
    assert_equal [%w[a b], ['1,5', 'он сказал "да"']], rows
  end

  def test_csv_reader_reports_missing_file
    assert_raises(SmartRouting::InputError) { SmartRouting::Support::CsvReader.read('нет.csv') }
  end

  # --- калибровка ---

  def test_calibrator_computes_conversion
    calibrator = SmartRouting::Analytics::HistoryCalibrator.load(history_path)
    conversion = calibrator.conversion_by_provider
    assert_equal %w[payflow quickpay vipay], conversion.keys.sort
    conversion.each_value { |value| assert_includes 0.0..1.0, value }
  end

  def test_calibrator_shares_sum_to_hundred
    calibrator = SmartRouting::Analytics::HistoryCalibrator.load(history_path)
    total = calibrator.stats_by_provider.values.sum { |s| s['count_share_pct'] }
    assert_in_delta 100.0, total, 0.5
  end

  def test_calibrator_detects_conversion_drift
    calibrator = SmartRouting::Analytics::HistoryCalibrator.load(history_path)
    config = SmartRouting::Config.load
    providers = SmartRouting::Loaders.providers(providers_path, config)
    drift = calibrator.conversion_drift(providers)

    refute_empty drift, 'заявленная и фактическая конверсия в кейсе расходятся'
    drift.each { |item| assert item.key?('drift_pp') }
  end

  def test_calibrator_on_empty_history
    calibrator = SmartRouting::Analytics::HistoryCalibrator.new([])
    assert calibrator.empty?
    assert_equal 0, calibrator.total_count
    assert_empty calibrator.conversion_by_provider
  end

  # --- backtest ---

  def test_backtest_replays_full_history
    config = SmartRouting::Config.load
    result = SmartRouting::Analytics::Backtest.new(
      config: config, providers_path: providers_path, history_path: history_path
    ).run

    assert_equal 100, result['operations']
    assert_equal 100, result['routed_by_us']
    assert result['reset_daily']
    assert_operator result['share_error_pp']['ours'], :<, result['share_error_pp']['historical'],
                    'роутер должен уменьшать отклонение от целевых долей'
  end

  def test_backtest_without_reset_uses_snapshot_state
    config = SmartRouting::Config.load
    result = SmartRouting::Analytics::Backtest.new(
      config: config, providers_path: providers_path, history_path: history_path, reset_daily: false
    ).run
    refute result['reset_daily']
    assert_includes result['note'], 'как есть'
  end

  # --- сравнение профилей ---

  def test_profile_comparison_excludes_demo_profiles
    comparison = SmartRouting::Analytics::ProfileComparison.new(
      queue_path: queue_path, providers_path: providers_path, history_path: history_path
    )
    refute_includes comparison.profile_names, 'demo_failover'
    assert_includes SmartRouting::Analytics::ProfileComparison.new(
      queue_path: queue_path, providers_path: providers_path, include_demo: true
    ).profile_names, 'demo_failover'
  end

  def test_profile_comparison_counts_freedom_of_choice
    result = SmartRouting::Analytics::ProfileComparison.new(
      queue_path: queue_path, providers_path: providers_path, history_path: history_path
    ).run

    freedom = result['freedom_of_choice']
    assert_equal 10, freedom['total_operations']
    assert_equal 4, freedom['single_option'], 'в публичной очереди 4 безальтернативные заявки'
    assert_equal 6, freedom['with_real_choice']
    refute_empty result['verdict']
  end

  def test_profile_comparison_covers_every_profile
    result = SmartRouting::Analytics::ProfileComparison.new(
      queue_path: queue_path, providers_path: providers_path
    ).run

    result['profiles'].each do |name, run|
      assert_equal 10, run['assignment'].size, "профиль #{name}"
      assert run.key?('share_error_pp')
    end
  end

  # --- дашборд ---

  def test_dashboard_renders_valid_html
    decisions, pool, config, calibrator = PipelineTest.run_pipeline
    report = SmartRouting::Analytics::ReportBuilder.new(
      decisions: decisions, pool: pool, config: config, calibrator: calibrator
    ).build

    html = SmartRouting::Analytics::Dashboard.new(report, decisions: decisions.map(&:to_h)).render
    assert_includes html, '<!DOCTYPE html>'
    assert_includes html, 'Распределение по провайдерам'
    assert_includes html, 'vipay'
    assert_equal 1, html.scan('</html>').size
  end

  def test_dashboard_escapes_html_in_data
    report = { 'period' => '<script>alert(1)</script>', 'total_operations' => 0,
               'distribution' => {}, 'skip_reasons' => {}, 'recommendations_detailed' => [] }
    html = SmartRouting::Analytics::Dashboard.new(report).render
    refute_includes html, '<script>alert(1)</script>'
    assert_includes html, '&lt;script&gt;'
  end

  def test_dashboard_survives_minimal_report
    html = SmartRouting::Analytics::Dashboard.new({ 'total_operations' => 0 }).render
    assert_includes html, '</html>'
  end
end
