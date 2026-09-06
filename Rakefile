# frozen_string_literal: true

# Задачи проекта. Внешних гемов нет: только rake из стандартной поставки Ruby.

RUBY_BIN = RbConfig.ruby

def sh_ruby(*args)
  sh RUBY_BIN, *args
end

desc 'Запустить все тесты'
task :test do
  files = FileList['test/**/*_test.rb']
  abort 'Тесты не найдены' if files.empty?
  sh_ruby '-e', files.map { |f| "require './#{f}'" }.join('; ')
end

desc 'Прогнать публичную очередь из 10 заявок (PROFILE=balanced)'
task :route do
  args = ['bin/route']
  args += ['--profile', ENV['PROFILE']] if ENV['PROFILE']
  sh_ruby(*args)
end

desc 'Проверить результат валидатором организаторов (FILE=..., QUEUE=...)'
task :validate do
  file = ENV['FILE'] || 'routing_decisions.json'
  abort "Файл не найден: #{file}. Сначала выполните rake route" unless File.exist?(file)

  # По умолчанию валидатор сверяется с публичной очередью из 10 заявок.
  # На стопкоде очередь другая — передаём её через QUEUE=.
  ENV['QUEUE_FILE'] = ENV['QUEUE'] if ENV['QUEUE']
  sh_ruby 'scripts/validate_10.rb', file
end

desc 'Сформировать сдаваемые routing_decisions_test.json и routing_report_test.json'
task :submit do
  require 'json'

  queue = ENV['QUEUE'] || 'data/operations_queue_test.json'
  unless File.exist?(queue)
    abort <<~MSG
      Не найдена тестовая очередь: #{queue}

      Положите выданный организаторами operations_queue_test.json в data/
      и запустите заново:  rake submit
      Либо укажите путь явно: rake submit QUEUE=путь/к/файлу.json
    MSG
  end

  decisions_file = 'routing_decisions_test.json'
  report_file = 'routing_report_test.json'

  begin
    sh_ruby 'bin/route',
            '--queue', queue,
            '--decisions', decisions_file,
            '--report', report_file
  rescue RuntimeError
    abort "\nРоутер не отработал — смотрите сообщение об ошибке выше. Файлы не сформированы."
  end

  # --- Самопроверка: то, что раньше делалось руками по чек-листу ---
  problems = []

  ops = JSON.parse(File.read(queue))
  problems << "очередь #{queue} пустая — это почти наверняка не тот файл" if ops.empty?
  decisions = JSON.parse(File.read(decisions_file))

  problems << "решений #{decisions.size}, а заявок в очереди #{ops.size}" if decisions.size != ops.size

  queue_ids = ops.map { |o| o['operation_id'] }
  decision_ids = decisions.map { |d| d['operation_id'] }
  missing = queue_ids - decision_ids
  extra = decision_ids - queue_ids
  problems << "нет решений для: #{missing.join(', ')}" if missing.any?
  problems << "лишние operation_id: #{extra.join(', ')}" if extra.any?

  [decisions_file, report_file].each do |f|
    problems << "#{f} не в корне репозитория" unless File.exist?(File.join(Dir.pwd, f))
    problems << "#{f} пустой" if File.exist?(f) && File.size(f).zero?
  end

  puts
  puts '=== Валидатор организаторов ==='
  ENV['QUEUE_FILE'] = queue
  problems << 'валидатор организаторов вернул ошибки' unless system(RUBY_BIN, 'scripts/validate_10.rb', decisions_file)

  puts
  if problems.empty?
    puts '=== ГОТОВО К СДАЧЕ ==='
    puts "  заявок в очереди: #{ops.size}, решений: #{decisions.size}"
    puts "  #{decisions_file}, #{report_file} — в корне, валидатор чист"
    puts
    puts 'Осталось: git add + commit + push в main, затем глазами проверить оба файла на GitHub.'
  else
    puts '=== НЕ СДАВАТЬ, ЕСТЬ ПРОБЛЕМЫ ==='
    problems.each { |p| puts "  ✗ #{p}" }
    abort
  end
end

desc 'Анализ истории операций'
task :analyze do
  sh_ruby 'bin/analyze'
end

desc 'Переиграть историю через наш роутер'
task :backtest do
  args = ['bin/backtest']
  args += ['--profile', ENV['PROFILE']] if ENV['PROFILE']
  sh_ruby(*args)
end

desc 'Сравнить профили роутинга'
task :compare do
  args = ['bin/compare']
  args << '--backtest' if ENV['BACKTEST']
  sh_ruby(*args)
end

desc 'Демонстрация каскада и fallback (профиль demo_failover)'
task :demo do
  sh_ruby 'bin/route',
          '--profile', 'demo_failover',
          '--decisions', 'out/demo_decisions.json',
          '--report', 'out/demo_report.json'
end

desc 'Собрать HTML-дашборд из отчёта'
task :dashboard do
  Rake::Task[:route].invoke unless File.exist?('routing_report.json')
  sh_ruby 'bin/dashboard'
end

desc 'Полный прогон: тесты, роутинг, валидатор, аналитика, дашборд'
task all: %i[test route validate analyze backtest compare dashboard]

task default: %i[test route validate]
