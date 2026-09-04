# frozen_string_literal: true

require 'optparse'

module SmartRouting
  # Точка входа bin/route: собрать пайплайн, прогнать очередь, записать
  # решения и отчёт. Все параметры имеют разумные значения по умолчанию,
  # так что `ruby bin/route` работает без единого флага.
  class CLI
    DEFAULTS = {
      queue: 'data/operations_queue_10.json',
      providers: 'data/providers.json',
      history: 'data/operations_history.csv',
      config: nil,
      profile: nil,
      decisions: 'routing_decisions.json',
      report: 'routing_report.json',
      period: nil,
      quiet: false
    }.freeze

    def self.run(argv, out: $stdout)
      new(argv, out: out).run
    end

    def initialize(argv, out: $stdout)
      @out = out
      @options = DEFAULTS.dup
      parse!(argv)
    end

    def run
      config = Config.load(@options[:config], profile: @options[:profile])
      calibrator = load_calibrator
      providers = Loaders.providers(@options[:providers], config)
      operations = Loaders.operations(@options[:queue])

      pool = ProviderPool.new(providers, config: config, warm_start: warm_start(config, calibrator))
      scorer = Scoring::CompositeScorer.new(
        config,
        Strategies::Registry.build(config, observed_conversion: calibrator&.conversion_by_provider || {})
      )
      router = Router.new(pool: pool, config: config, scorer: scorer, simulator: Simulator.new(config))

      decisions = router.route_all(operations)
      report = Analytics::ReportBuilder.new(
        decisions: decisions, pool: pool, config: config,
        calibrator: calibrator, period: period_for(operations)
      ).build

      Loaders.write_json(@options[:decisions], decisions.map(&:to_h))
      Loaders.write_json(@options[:report], report)
      print_summary(config, decisions, report) unless @options[:quiet]
      0
    rescue SmartRouting::Error => e
      warn "Ошибка: #{e.message}"
      1
    end

    private

    def parse!(argv)
      parser = OptionParser.new do |opts|
        opts.banner = 'Использование: ruby bin/route [опции]'
        opts.on('-q', '--queue PATH', 'очередь заявок (JSON)') { |v| @options[:queue] = v }
        opts.on('-p', '--providers PATH', 'снимок провайдеров (JSON)') { |v| @options[:providers] = v }
        opts.on('-c', '--config PATH', 'конфигурация роутинга (YAML)') { |v| @options[:config] = v }
        opts.on('-P', '--profile NAME', 'профиль роутинга из конфига') { |v| @options[:profile] = v }
        opts.on('-H', '--history PATH', 'история операций (CSV), "none" чтобы не читать') { |v| @options[:history] = v }
        opts.on('-d', '--decisions PATH', 'куда записать решения') { |v| @options[:decisions] = v }
        opts.on('-r', '--report PATH', 'куда записать отчёт') { |v| @options[:report] = v }
        opts.on('--period DATE', 'период для отчёта (YYYY-MM-DD)') { |v| @options[:period] = v }
        opts.on('--quiet', 'не печатать сводку') { @options[:quiet] = true }
        opts.on('-h', '--help', 'показать справку') do
          @out.puts opts
          exit 0
        end
      end
      parser.parse!(argv)
    rescue OptionParser::ParseError => e
      raise InputError, e.message
    end

    def load_calibrator
      path = @options[:history]
      return nil if path.nil? || path == 'none' || !File.file?(path)

      Analytics::HistoryCalibrator.load(path)
    end

    def warm_start(config, calibrator)
      return nil unless config.profile['warm_start'] == true
      return nil if calibrator.nil? || calibrator.empty?

      calibrator.warm_start
    end

    def period_for(operations)
      return @options[:period] if @options[:period]

      Loaders.snapshot_period(@options[:providers]) ||
        operations.filter_map(&:created_at).min&.strftime('%Y-%m-%d')
    end

    def print_summary(config, decisions, report)
      @out.puts "Профиль роутинга: #{config.profile_name} — #{config.profile_description}"
      @out.puts "Обработано заявок: #{decisions.size}"
      @out.puts
      @out.puts format('%-16s %6s %8s %8s %10s', 'провайдер', 'заявок', 'факт %', 'цель %', 'откл. п.п.')
      report['distribution'].each do |name, stat|
        @out.puts format('%-16s %6d %8.1f %8.1f %10.1f',
                         name, stat['count'], stat['share_pct'], stat['target_pct'], stat['deviation_pp'])
      end
      @out.puts
      results = report['results']
      @out.puts "Исходы: approved #{results['approved']}, rejected #{results['rejected']}, " \
                "expired #{results['expired']} (успешность #{(results['approval_rate'] * 100).round(1)}%)"
      unless report['skip_reasons'].empty?
        @out.puts "Причины отсева: #{report['skip_reasons'].map { |k, v| "#{k} ×#{v}" }.join(', ')}"
      end
      @out.puts
      @out.puts 'Рекомендации:'
      report['recommendations'].each { |text| @out.puts "  • #{text}" }
      @out.puts
      @out.puts "Записано: #{@options[:decisions]}, #{@options[:report]}"
    end
  end
end
