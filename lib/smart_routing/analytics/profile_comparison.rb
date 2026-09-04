# frozen_string_literal: true

module SmartRouting
  module Analytics
    # Прогон одной и той же очереди под всеми профилями роутинга.
    #
    # Отвечает на вопрос «а что было бы при другой политике» и заодно
    # показывает, где выбор политики вообще ни на что не влияет: если у
    # заявки единственный допустимый провайдер, никакая стратегия его
    # не изменит.
    class ProfileComparison
      def initialize(queue_path:, providers_path:, history_path: nil, config_path: nil, include_demo: false)
        @queue_path = queue_path
        @providers_path = providers_path
        @history_path = history_path
        @config_path = config_path
        @include_demo = include_demo
      end

      # Демо-профили отличаются симуляцией, а не политикой выбора,
      # поэтому по умолчанию в сравнении политик не участвуют.
      def profile_names
        raw = YAML.safe_load(File.read(@config_path || Config::DEFAULT_PATH), aliases: true)
        profiles = raw['profiles'] || {}
        profiles.reject { |_, body| !@include_demo && body.is_a?(Hash) && body['demo'] == true }.keys
      end

      def run
        runs = profile_names.to_h { |name| [name, run_profile(name)] }
        {
          'profiles' => runs,
          'agreement' => agreement(runs),
          'freedom_of_choice' => freedom_of_choice(runs),
          'verdict' => verdict(runs)
        }
      end

      # Короткий вывод: влияет ли выбор политики на этой очереди вообще.
      def verdict(runs)
        divergent = agreement(runs)['divergent']
        freedom = freedom_of_choice(runs)
        return 'Профили расходятся — политика влияет на распределение' unless divergent.empty?

        "Все содержательные профили дали одинаковое распределение: #{freedom['single_option']} " \
          "из #{freedom['total_operations']} заявок безальтернативны по hard-constraints, " \
          'а на остальных сигналы стратегий указывают на одного и того же провайдера. ' \
          'Расхождение политик видно на большом объёме — см. bin/backtest.'
      end

      private

      def calibrator
        return @calibrator if defined?(@calibrator)

        @calibrator = @history_path && File.file?(@history_path) ? HistoryCalibrator.load(@history_path) : nil
      end

      def run_profile(name)
        config = Config.load(@config_path, profile: name)
        providers = Loaders.providers(@providers_path, config)
        operations = Loaders.operations(@queue_path)
        pool = ProviderPool.new(providers, config: config)
        scorer = Scoring::CompositeScorer.new(
          config, Strategies::Registry.build(config, observed_conversion: calibrator&.conversion_by_provider || {})
        )
        router = Router.new(pool: pool, config: config, scorer: scorer, simulator: Simulator.new(config))
        decisions = router.route_all(operations)

        {
          'description' => config.profile_description.strip,
          'assignment' => decisions.to_h { |d| [d.operation.id, d.selected_provider] },
          'distribution' => distribution(decisions, pool),
          'share_error_pp' => share_error(decisions, pool),
          'expected_conversion' => expected_conversion(decisions),
          'fallback_used' => decisions.count(&:fallback_used)
        }
      end

      def distribution(decisions, pool)
        counts = decisions.group_by(&:selected_provider).transform_values(&:size)
        pool.routable.to_h do |provider|
          [provider.name, {
            'count' => counts.fetch(provider.name, 0),
            'share_pct' => Support::Numeric.pct(counts.fetch(provider.name, 0), decisions.size),
            'target_pct' => provider.traffic_percentage
          }]
        end
      end

      def share_error(decisions, pool)
        counts = decisions.group_by(&:selected_provider).transform_values(&:size)
        Support::Numeric.round2(
          pool.routable.sum do |provider|
            (Support::Numeric.pct(counts.fetch(provider.name, 0), decisions.size) -
              provider.traffic_percentage).abs
          end
        )
      end

      def expected_conversion(decisions)
        observed = calibrator&.conversion_by_provider || {}
        return nil if observed.empty?

        Support::Numeric.round2(
          Support::Numeric.safe_div(
            decisions.sum { |d| observed.fetch(d.selected_provider, 0.0) }, decisions.size
          )
        )
      end

      # По каким заявкам профили сходятся, а по каким расходятся.
      def agreement(runs)
        assignments = runs.values.map { |run| run['assignment'] }
        return { 'identical' => [], 'divergent' => {} } if assignments.empty?

        identical = []
        divergent = {}
        assignments.first.each_key do |op_id|
          chosen = runs.transform_values { |run| run['assignment'][op_id] }
          if chosen.values.uniq.size == 1
            identical << op_id
          else
            divergent[op_id] = chosen
          end
        end
        { 'identical' => identical, 'divergent' => divergent }
      end

      # Сколько заявок вообще допускали выбор: если допустимый провайдер один,
      # различие профилей на этой заявке невозможно по определению.
      def freedom_of_choice(runs)
        config = Config.load(@config_path)
        providers = Loaders.providers(@providers_path, config)
        operations = Loaders.operations(@queue_path)
        pool = ProviderPool.new(providers, config: config)
        chain = Constraints::Chain.new(Constraints::Registry.build(config))

        counts = operations.map do |operation|
          pool.routable.count { |provider| chain.check(provider, operation, pool).nil? }
        end

        {
          'total_operations' => operations.size,
          'single_option' => counts.count { |c| c <= 1 },
          'with_real_choice' => counts.count { |c| c > 1 },
          'divergent_operations' => runs.empty? ? 0 : agreement(runs)['divergent'].size
        }
      end
    end
  end
end
