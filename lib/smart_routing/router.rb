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

      outcome = walk_cascade(operation, ranked, attempts)

      raise NoProviderError, "#{operation.id}: не осталось ни одного провайдера, включая self-provider" if outcome.nil?

      record_not_reached(ranked, outcome[:attempted], outcome[:provider], attempts)
      finalize(operation, outcome, ranked, attempts, eligible)
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
    #
    # Поводом идти дальше всегда служит отказ провайдера принять заявку в работу.
    # Неуспешная выплата у принявшего провайдера — терминальный исход, и маршрут
    # она не меняет; при retry_on_terminal_failure: true заявка переезжает
    # к следующему кандидату и в этом случае тоже.
    #
    # @return [Hash, nil] provider, card, result, latency_sec, attempted, fallback
    def walk_cascade(operation, ranked, attempts)
      attempted = []
      queue = ranked.take(config.max_attempts)

      until queue.empty?
        provider, card = queue.shift
        attempted << provider.name

        next unless accepted?(operation, provider, card, attempts)

        # Объяснение снимается до обработки: оно описывает состояние пула
        # в момент решения, а не после того, как заявка уже занята провайдером.
        explanation = explanations(operation, provider)
        result, latency = process(operation, provider)
        unless retry_after_failure?(result, queue)
          return { provider: provider, card: card, result: result, latency: latency,
                   attempted: attempted, fallback: false, explanation: explanation }
        end

        attempts << Models::Attempt.skipped(
          provider.name, 'terminal_failure',
          "выплата не прошла (#{result}, #{latency} с), " \
          'перемаршрутизируем на следующего кандидата',
          score: card.total, stage: 'cascade'
        )
      end

      fall_back(operation, attempts, attempted)
    end

    # Принял ли провайдер заявку в работу; отказ и таймаут сразу пишутся в attempts.
    def accepted?(operation, provider, card, attempts)
      case simulator.handoff(operation, provider)
      when :accepted
        true
      when :timeout
        attempts << Models::Attempt.skipped(
          provider.name, 'provider_timeout',
          'провайдер не ответил в отведённое время, переходим к следующему кандидату',
          score: card.total, stage: 'cascade'
        )
        false
      else
        attempts << Models::Attempt.skipped(
          provider.name, 'provider_declined',
          'провайдер отказался принять заявку, переходим к следующему кандидату',
          score: card.total, stage: 'cascade'
        )
        false
      end
    end

    def retry_after_failure?(result, queue)
      config.retry_on_terminal_failure? && result != 'approved' && !queue.empty?
    end

    # Симуляция исхода и обновление состояния пула: слот и лимит заняты
    # тем провайдером, который заявку действительно обработал.
    def process(operation, provider)
      result, latency = simulator.outcome(operation, provider, conversion: conversion_for(provider))
      pool.occupy(provider, operation, latency, result)
      [result, latency]
    end

    # Шаг 5: self-provider. Он вне обычного пула и берётся только когда
    # внешних вариантов не осталось — но hard-constraints проверяются и для него.
    def fall_back(operation, attempts, attempted)
      provider = pool.fallback
      return nil if provider.nil?

      verdict = constraints.check(provider, operation, pool)
      if verdict
        attempts << Models::Attempt.skipped(provider.name, verdict.reason, verdict.details, stage: 'fallback')
        return nil
      end

      explanation = explanations(operation, provider)
      result, latency = process(operation, provider)
      { provider: provider, card: nil, result: result, latency: latency,
        attempted: attempted, fallback: true, explanation: explanation }
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

    # Шаг 6: фиксируем выбор и собираем решение. Исход уже получен в каскаде:
    # состояние пула обновляется на каждой попытке, которая дошла до обработки.
    def finalize(operation, outcome, ranked, attempts, eligible)
      selected = outcome[:provider]
      card = outcome[:card]
      fallback_used = outcome[:fallback]
      reason, details = selection_reason(selected, card, ranked, eligible, fallback_used,
                                         outcome[:explanation])

      attempts << Models::Attempt.selected(
        selected.name, reason, details,
        score: card&.total, breakdown: card&.to_h
      )

      Models::Decision.new(
        operation: operation,
        selected_provider: selected.name,
        attempts: order_attempts(attempts),
        simulated_result: outcome[:result],
        latency_sec: outcome[:latency],
        eligible: eligible.map(&:name),
        profile: config.profile_name,
        fallback_used: fallback_used
      )
    end

    def selection_reason(selected, card, ranked, eligible, fallback_used, explanation)
      if fallback_used
        return ['fallback_self_provider',
                'внешних допустимых провайдеров не осталось, заявка ушла на self-provider']
      end

      if eligible.size == 1
        return ['only_eligible_provider',
                "единственный провайдер, прошедший hard-constraints; #{explanation}"]
      end

      runner_up = ranked.find { |provider, _| provider.name != selected.name }&.last
      reason = ranked.first&.first&.name == selected.name ? 'best_composite_score' : 'best_available_after_retry'
      [reason, "#{scorer.explain_win(card, runner_up)}. #{explanation}"]
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
