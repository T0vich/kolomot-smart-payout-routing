# frozen_string_literal: true

module SmartRouting
  # Оркестратор роутинга одной очереди.
  #
  # Порядок работы по каждой заявке:
  #   1. продвинуть модельное время — освободить завершившиеся in-progress;
  #   2. применить hard-constraints и получить допустимый пул;
  #   3. отранжировать пул композитным скорингом;
  #   4. пройти каскад попыток: отказ ⇒ следующий кандидат;
  #   5. если внешних кандидатов не осталось — уйти на self-provider;
  #   6. симулировать исход и обновить состояние пула.
  class Router
    attr_reader :pool, :config, :scorer, :simulator, :constraints

    def initialize(pool:, config:, scorer:, simulator:)
      @pool = pool
      @config = config
      @scorer = scorer
      @simulator = simulator
      @constraints = Constraints::Chain.new(Constraints::Registry.build(config))
    end

    # @param operations [Array<Models::Operation>]
    # @return [Array<Models::Decision>]
    def route_all(operations)
      decisions = operations.map { |operation| route(operation) }
      pool.drain!
      decisions
    end

    def route(operation)
      pool.advance_clock(operation.created_at)

      attempts = []
      eligible = filter_eligible(operation, attempts)
      ranked = scorer.rank(eligible, operation, pool)

      selected, card, attempted = walk_cascade(operation, ranked, attempts)
      selected, card = fall_back(operation, attempts) if selected.nil?

      raise NoProviderError, "#{operation.id}: не осталось ни одного провайдера, включая self-provider" if selected.nil?

      record_not_reached(ranked, attempted, selected, attempts)
      finalize(operation, selected, card, ranked, attempts, eligible)
    end

    private

    # Шаг 2: жёсткие ограничения. Каждый отсеянный провайдер сразу попадает
    # в attempts с конкретной причиной — это и есть объяснимость исключений.
    def filter_eligible(operation, attempts)
      pool.routable.each_with_object([]) do |provider, eligible|
        verdict = constraints.check(provider, operation, pool)
        if verdict.nil?
          eligible << provider
        else
          attempts << Models::Attempt.skipped(provider.name, verdict.reason, verdict.details)
        end
      end
    end

    # Шаг 4: каскад. Кандидаты обходятся в порядке убывания скора,
    # но не больше max_attempts попыток подряд.
    def walk_cascade(operation, ranked, attempts)
      attempted = []

      ranked.take(config.max_attempts).each do |provider, card|
        attempted << provider.name
        case simulator.handoff(operation, provider)
        when :accepted
          return [provider, card, attempted]
        when :timeout
          attempts << Models::Attempt.skipped(
            provider.name, 'provider_timeout',
            'провайдер не ответил в отведённое время, переходим к следующему кандидату',
            score: card.total, stage: 'cascade'
          )
        else
          attempts << Models::Attempt.skipped(
            provider.name, 'provider_declined',
            'провайдер отказался принять заявку, переходим к следующему кандидату',
            score: card.total, stage: 'cascade'
          )
        end
      end

      [nil, nil, attempted]
    end

    # Шаг 5: self-provider. Он вне обычного пула и берётся только когда
    # внешних вариантов не осталось — но hard-constraints проверяются и для него.
    def fall_back(operation, attempts)
      provider = pool.fallback
      return [nil, nil] if provider.nil?

      verdict = constraints.check(provider, operation, pool)
      if verdict
        attempts << Models::Attempt.skipped(provider.name, verdict.reason, verdict.details, stage: 'fallback')
        return [nil, nil]
      end

      [provider, nil]
    end

    # Кандидаты, до которых очередь не дошла: они были допустимы,
    # но проиграли по баллу. Причину исключения жюри требует и для них.
    def record_not_reached(ranked, attempted, selected, attempts)
      ranked.each do |provider, card|
        next if provider.name == selected.name
        next if attempted.include?(provider.name)

        attempts << Models::Attempt.skipped(
          provider.name, 'lower_score',
          "балл #{format('%.2f', card.total)} ниже, чем у выбранного провайдера",
          score: card.total, breakdown: card.to_h, stage: 'scoring'
        )
      end
    end

    # Шаг 6: фиксируем выбор, симулируем исход, обновляем состояние пула.
    def finalize(operation, selected, card, ranked, attempts, eligible)
      fallback_used = card.nil?
      reason, details = selection_reason(operation, selected, card, ranked, eligible, fallback_used)

      attempts << Models::Attempt.selected(
        selected.name, reason, details,
        score: card&.total, breakdown: card&.to_h
      )

      conversion = conversion_for(selected)
      result, latency = simulator.outcome(operation, selected, conversion: conversion)
      pool.occupy(selected, operation, latency, result)

      Models::Decision.new(
        operation: operation,
        selected_provider: selected.name,
        attempts: order_attempts(attempts),
        simulated_result: result,
        latency_sec: latency,
        eligible: eligible.map(&:name),
        profile: config.profile_name,
        fallback_used: fallback_used
      )
    end

    def selection_reason(operation, selected, card, ranked, eligible, fallback_used)
      if fallback_used
        return ['fallback_self_provider',
                'внешних допустимых провайдеров не осталось, заявка ушла на self-provider']
      end

      if eligible.size == 1
        return ['only_eligible_provider',
                "единственный провайдер, прошедший hard-constraints; #{explanations(operation, selected)}"]
      end

      runner_up = ranked.find { |provider, _| provider.name != selected.name }&.last
      reason = ranked.first&.first&.name == selected.name ? 'best_composite_score' : 'best_available_after_retry'
      [reason, "#{scorer.explain_win(card, runner_up)}. #{explanations(operation, selected)}"]
    end

    # Пояснения каждой стратегии по выбранному провайдеру — человеческим языком.
    def explanations(operation, provider)
      scorer.strategies.filter_map do |strategy|
        strategy.explain(provider, operation, pool)
      end.join('; ')
    end

    def conversion_for(provider)
      strategy = scorer.strategies_by_key['conversion']
      strategy.respond_to?(:effective) ? strategy.effective(provider) : provider.conversion_24h
    end

    # Порядок в attempts: сначала жёсткий отсев, затем каскад попыток,
    # затем выбранный, затем проигравшие по баллу. Так читается хронология.
    ATTEMPT_ORDER = { 'hard_filter' => 0, 'cascade' => 1, 'fallback' => 2, 'routed' => 3, 'scoring' => 4 }.freeze

    def order_attempts(attempts)
      attempts.each_with_index.sort_by { |attempt, index| [ATTEMPT_ORDER.fetch(attempt.stage, 5), index] }
              .map(&:first)
    end
  end
end
