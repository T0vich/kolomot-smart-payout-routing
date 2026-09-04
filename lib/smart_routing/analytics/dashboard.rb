# frozen_string_literal: true

module SmartRouting
  module Analytics
    # Статическая HTML-страница по routing_report.json.
    #
    # Генератор целиком на Ruby и не тянет ни одной внешней библиотеки:
    # стили инлайновые, скриптов нет, диаграммы нарисованы через CSS-ширины.
    # Страница нужна для защиты — читать JSON с экрана неудобно.
    class Dashboard
      def initialize(report, decisions: nil, title: 'Роутинг выплат — отчёт')
        @report = report
        @decisions = decisions
        @title = title
      end

      def render
        <<~HTML
          <!DOCTYPE html>
          <html lang="ru">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{escape(@title)}</title>
          <style>#{styles}</style>
          </head>
          <body>
          <main>
            <h1>#{escape(@title)}</h1>
            #{summary_section}
            #{distribution_section}
            #{utilization_section}
            #{skips_section}
            #{recommendations_section}
            #{decisions_section}
            <footer>Сгенерировано bin/dashboard, команда «Коломот»</footer>
          </main>
          </body>
          </html>
        HTML
      end

      private

      def styles
        <<~CSS
          :root { --bg:#f6f7f9; --card:#fff; --ink:#1c1f23; --muted:#6b7480;
                  --line:#e3e6ea; --good:#2f855a; --warn:#b7791f; --bad:#c53030; --accent:#3563d6; }
          * { box-sizing: border-box; }
          body { margin:0; background:var(--bg); color:var(--ink);
                 font:15px/1.5 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif; }
          main { max-width:1040px; margin:0 auto; padding:32px 20px 64px; }
          h1 { font-size:26px; margin:0 0 4px; }
          h2 { font-size:18px; margin:32px 0 12px; }
          section { background:var(--card); border:1px solid var(--line); border-radius:10px;
                    padding:18px 20px; margin-bottom:18px; }
          table { width:100%; border-collapse:collapse; font-size:14px; }
          th,td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); }
          th { color:var(--muted); font-weight:600; font-size:12px; text-transform:uppercase;
               letter-spacing:.04em; }
          td.num, th.num { text-align:right; font-variant-numeric:tabular-nums; }
          .tiles { display:flex; flex-wrap:wrap; gap:12px; }
          .tile { flex:1 1 150px; background:var(--card); border:1px solid var(--line);
                  border-radius:10px; padding:14px 16px; }
          .tile b { display:block; font-size:24px; font-variant-numeric:tabular-nums; }
          .tile span { color:var(--muted); font-size:12px; text-transform:uppercase;
                       letter-spacing:.04em; }
          .bar { height:8px; background:var(--line); border-radius:4px; overflow:hidden; min-width:120px; }
          .bar i { display:block; height:100%; background:var(--accent); }
          .good { color:var(--good); } .warn { color:var(--warn); } .bad { color:var(--bad); }
          ul { margin:0; padding-left:20px; } li { margin-bottom:8px; }
          details { margin-bottom:10px; }
          summary { cursor:pointer; font-weight:600; }
          code { background:var(--bg); padding:1px 5px; border-radius:4px; font-size:13px; }
          footer { color:var(--muted); font-size:12px; margin-top:28px; }
        CSS
      end

      def summary_section
        results = @report['results'] || {}
        profile = @report['routing_profile'] || {}
        <<~HTML
          <section>
            <div class="tiles">
              #{tile('Заявок', @report['total_operations'])}
              #{tile('Одобрено', results['approved'])}
              #{tile('Отказов', results['rejected'])}
              #{tile('Просрочено', results['expired'])}
              #{tile('Успешность', "#{((results['approval_rate'] || 0) * 100).round(1)}%")}
              #{tile('Ср. задержка', "#{results['avg_latency_sec']} c")}
            </div>
            <p style="color:var(--muted);margin:14px 0 0">
              Период #{escape(@report['period'])} · профиль <code>#{escape(profile['name'])}</code>
              — #{escape(profile['description'].to_s.strip)}
            </p>
          </section>
        HTML
      end

      def tile(label, value)
        %(<div class="tile"><span>#{escape(label)}</span><b>#{escape(value)}</b></div>)
      end

      def distribution_section
        rows = (@report['distribution'] || {}).map do |name, stat|
          deviation = stat['deviation_pp'].to_f
          css = deviation.abs < 5 ? 'good' : (deviation.abs < 15 ? 'warn' : 'bad')
          <<~ROW
            <tr>
              <td>#{escape(name)}</td>
              <td class="num">#{stat['count']}</td>
              <td class="num">#{stat['share_pct']}%</td>
              <td class="num">#{stat['target_pct']}%</td>
              <td class="num #{css}">#{format('%+.1f', deviation)}</td>
              <td style="width:180px">#{bar(stat['share_pct'])}</td>
              <td class="num">#{stat['volume_share_pct']}%</td>
              <td class="num">#{stat['conversion']}</td>
            </tr>
          ROW
        end.join
        <<~HTML
          <h2>Распределение по провайдерам</h2>
          <section>
            <table>
              <tr><th>провайдер</th><th class="num">заявок</th><th class="num">факт</th>
                  <th class="num">цель</th><th class="num">откл. п.п.</th><th>доля</th>
                  <th class="num">объём</th><th class="num">конверсия</th></tr>
              #{rows}
            </table>
          </section>
        HTML
      end

      def utilization_section
        rows = (@report['projected_daily_utilization'] || {}).map do |name, stat|
          pct = stat['utilization_pct'].to_f
          css = pct < 70 ? 'good' : (pct < 90 ? 'warn' : 'bad')
          <<~ROW
            <tr>
              <td>#{escape(name)}</td>
              <td class="num">#{stat['used']}</td>
              <td class="num">#{stat['limit']}</td>
              <td class="num #{css}">#{pct}%</td>
              <td style="width:220px">#{bar(pct)}</td>
            </tr>
          ROW
        end.join
        return '' if rows.empty?

        <<~HTML
          <h2>Использование дневных лимитов</h2>
          <section>
            <table>
              <tr><th>провайдер</th><th class="num">оборот</th><th class="num">лимит</th>
                  <th class="num">загрузка</th><th></th></tr>
              #{rows}
            </table>
          </section>
        HTML
      end

      def skips_section
        hard = @report['skip_reasons'] || {}
        soft = @report['soft_skip_reasons'] || {}
        return '' if hard.empty? && soft.empty?

        <<~HTML
          <h2>Причины исключения провайдеров</h2>
          <section>
            <table>
              <tr><th>причина</th><th class="num">раз</th><th>тип</th></tr>
              #{hard.map { |r, c| skip_row(r, c, 'жёсткое ограничение') }.join}
              #{soft.map { |r, c| skip_row(r, c, 'проигрыш по баллу') }.join}
            </table>
          </section>
        HTML
      end

      def skip_row(reason, count, kind)
        %(<tr><td><code>#{escape(reason)}</code></td><td class="num">#{count}</td><td>#{escape(kind)}</td></tr>)
      end

      def recommendations_section
        items = (@report['recommendations_detailed'] || []).map do |item|
          parameter = item['parameter'] ? " <code>#{escape(item['parameter'])}</code>" : ''
          "<li>#{escape(item['text'])}#{parameter}</li>"
        end.join
        return '' if items.empty?

        "<h2>Рекомендации</h2>\n<section><ul>#{items}</ul></section>"
      end

      def decisions_section
        return '' if @decisions.nil? || @decisions.empty?

        blocks = @decisions.map do |decision|
          attempts = decision['attempts'].map do |attempt|
            mark = attempt['decision'] == 'selected' ? '✔' : '✖'
            css = attempt['decision'] == 'selected' ? 'good' : 'muted'
            %(<tr><td class="#{css}">#{mark} #{escape(attempt['provider'])}</td>) +
              %(<td><code>#{escape(attempt['reason'])}</code></td>) +
              %(<td>#{escape(attempt['details'])}</td></tr>)
          end.join
          <<~BLOCK
            <details>
              <summary>#{escape(decision['operation_id'])} → #{escape(decision['selected_provider'])}
              (#{escape(decision['simulated_result'])}, #{decision['latency_sec']} c)</summary>
              <table>#{attempts}</table>
            </details>
          BLOCK
        end.join
        "<h2>Решения по заявкам</h2>\n<section>#{blocks}</section>"
      end

      def bar(percent)
        width = [[percent.to_f, 0].max, 100].min
        %(<div class="bar"><i style="width:#{width}%"></i></div>)
      end

      def escape(value)
        value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end
    end
  end
end
