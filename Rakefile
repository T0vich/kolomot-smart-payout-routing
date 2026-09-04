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

desc 'Проверить результат валидатором организаторов (FILE=routing_decisions.json)'
task :validate do
  file = ENV['FILE'] || 'routing_decisions.json'
  abort "Файл не найден: #{file}. Сначала выполните rake route" unless File.exist?(file)
  sh_ruby 'scripts/validate_10.rb', file
end

desc 'Сформировать сдаваемые routing_decisions_test.json и routing_report_test.json'
task :submit do
  queue = ENV['QUEUE'] || 'data/operations_queue_test.json'
  unless File.exist?(queue)
    abort <<~MSG
      Не найдена тестовая очередь: #{queue}

      Положите выданный организаторами operations_queue_test.json в data/
      и запустите заново:  rake submit
      Либо укажите путь явно: rake submit QUEUE=путь/к/файлу.json
    MSG
  end

  sh_ruby 'bin/route',
          '--queue', queue,
          '--decisions', 'routing_decisions_test.json',
          '--report', 'routing_report_test.json'

  puts
  puts 'Проверьте перед коммитом:'
  puts '  1) оба файла лежат в корне репозитория;'
  puts '  2) количество решений совпадает с количеством заявок в выданной очереди;'
  puts '  3) rake validate FILE=routing_decisions_test.json проходит без ошибок;'
  puts '  4) файлы попали в ветку main.'
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
