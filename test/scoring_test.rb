# frozen_string_literal: true

require_relative 'test_helper'

class ScoringTest < Minitest::Test
  include TestHelper

  def test_score_card_totals_weighted_average
    card = SmartRouting::Scoring::ScoreCard.new(
      provider_name: 'alpha',
      parts: { 'traffic_share' => 1.0, 'conversion' => 0.0 },
      weights: { 'traffic_share' => 3.0, 'conversion' => 1.0 }
    )
    assert_in_delta 0.75, card.total, 1e-9
    assert_equal 'traffic_share', card.dominant_key
  end

  def test_score_card_handles_zero_weights
    card = SmartRouting::Scoring::ScoreCard.new(
      provider_name: 'alpha', parts: { 'traffic_share' => 1.0 }, weights: { 'traffic_share' => 0.0 }
    )
    assert_equal 0.0, card.total
  end

  # Явное разрешение конфликта: общий балл в пределах epsilon, решает
  # первая политика из conflict_order, по которой кандидаты различаются.
  def test_tie_is_resolved_by_conflict_order
    config = build_config(
      'weights' => { 'traffic_share' => 0.5, 'turnover_commitment' => 0.5 },
      'conflict_order' => %w[turnover_commitment traffic_share],
      'tie_break_epsilon' => 0.5
    )
    alpha = build_provider({ 'payment_system' => 'alpha', 'priority' => 1 },
                           { 'daily_turnover_min' => 1_000_000 })
    beta = build_provider({ 'payment_system' => 'beta', 'priority' => 2 })
    pool = build_pool([alpha, beta], config)
    scorer = SmartRouting::Scoring::CompositeScorer.new(config, SmartRouting::Strategies::Registry.build(config))

    ranked = scorer.rank([alpha, beta], build_operation, pool)
    assert_equal 'alpha', ranked.first.first.name,
                 'при ничье побеждает непокрытое обязательство по обороту'
  end

  def test_ranking_is_deterministic_for_identical_candidates
    config = build_config('weights' => { 'conversion' => 1.0 })
    first = build_provider('payment_system' => 'zeta', 'priority' => 5)
    second = build_provider('payment_system' => 'alpha', 'priority' => 5)
    pool = build_pool([first, second], config)
    scorer = SmartRouting::Scoring::CompositeScorer.new(config, SmartRouting::Strategies::Registry.build(config))

    3.times do
      ranked = scorer.rank([first, second], build_operation, pool)
      assert_equal 'alpha', ranked.first.first.name, 'полностью равные кандидаты сортируются по имени'
    end
  end

  def test_explain_win_mentions_runner_up
    config = build_config('weights' => { 'conversion' => 1.0 })
    strong = build_provider('payment_system' => 'alpha', 'conversion_24h' => 0.95)
    weak = build_provider('payment_system' => 'beta', 'conversion_24h' => 0.5)
    pool = build_pool([strong, weak], config)
    scorer = SmartRouting::Scoring::CompositeScorer.new(config, SmartRouting::Strategies::Registry.build(config))

    ranked = scorer.rank([strong, weak], build_operation, pool)
    text = scorer.explain_win(ranked[0][1], ranked[1][1])
    assert_includes text, 'beta'
  end

  def test_single_candidate_explanation
    config = build_config
    scorer = SmartRouting::Scoring::CompositeScorer.new(config, SmartRouting::Strategies::Registry.build(config))
    assert_equal 'единственный допустимый провайдер', scorer.explain_win(nil, nil)
  end
end
