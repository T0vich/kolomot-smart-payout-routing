# frozen_string_literal: true

module SmartRouting
  module Models
    # Одна попытка/рассмотрение провайдера для операции.
    #
    # Именно из этих записей складывается объяснимость: почему выбран один
    # провайдер и по какой конкретной причине выбыли остальные.
    class Attempt
      # Жёсткие причины отсева (hard-constraints).
      HARD_REASONS = %w[
        provider_inactive
        amount_below_minimum
        amount_exceeds_limit
        daily_limit_exceeded
        in_progress_count_limit
        in_progress_amount_limit
        bank_not_in_list
        bank_in_exclude_list
        margin_negative
        no_available_requisites
        rate_limit_exceeded
        daily_turnover_max_reached
      ].freeze

      # Мягкие причины: провайдер был допустим, но проиграл по скорингу
      # или до него не дошла очередь каскада.
      SOFT_REASONS = %w[lower_score not_reached provider_declined provider_timeout].freeze

      attr_reader :provider, :decision, :reason, :details, :score, :breakdown, :stage

      def self.skipped(provider, reason, details = nil, score: nil, breakdown: nil, stage: 'hard_filter')
        new(provider: provider, decision: 'skipped', reason: reason, details: details,
            score: score, breakdown: breakdown, stage: stage)
      end

      def self.selected(provider, reason, details = nil, score: nil, breakdown: nil)
        new(provider: provider, decision: 'selected', reason: reason, details: details,
            score: score, breakdown: breakdown, stage: 'routed')
      end

      def initialize(provider:, decision:, reason:, details: nil, score: nil, breakdown: nil, stage: nil)
        @provider = provider
        @decision = decision
        @reason = reason
        @details = details
        @score = score
        @breakdown = breakdown
        @stage = stage
      end

      def hard_skip?
        decision == 'skipped' && HARD_REASONS.include?(reason)
      end

      def soft_skip?
        decision == 'skipped' && SOFT_REASONS.include?(reason)
      end

      def to_h
        hash = { 'provider' => provider, 'decision' => decision, 'reason' => reason }
        hash['details'] = details if details && !details.empty?
        hash['stage'] = stage if stage
        hash['score'] = Support::Numeric.round2(score) if score
        hash['score_breakdown'] = breakdown if breakdown && !breakdown.empty?
        hash
      end
    end
  end
end
