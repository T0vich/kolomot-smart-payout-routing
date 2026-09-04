# frozen_string_literal: true

module SmartRouting
  module Support
    # Минимальный CSV-ридер под operations_history.csv.
    #
    # Стандартная библиотека csv в Ruby 3.4 стала bundled gem, а решение должно
    # запускаться на голом интерпретаторе без bundler — поэтому свой парсер.
    # Поддерживает кавычки, экранированные кавычки и переводы строк внутри поля.
    module CsvReader
      module_function

      # @return [Array<Hash{String=>String}>]
      def read(path)
        raise InputError, "CSV не найден: #{path}" unless File.file?(path)

        rows = parse(File.read(path, encoding: 'bom|utf-8'))
        return [] if rows.empty?

        header = rows.shift.map(&:strip)
        rows.reject { |r| r.all? { |cell| cell.nil? || cell.strip.empty? } }
            .map { |row| header.each_with_index.to_h { |name, i| [name, row[i]] } }
      end

      def parse(text)
        rows = []
        row = []
        field = +''
        in_quotes = false
        chars = text.chars
        i = 0

        while i < chars.length
          char = chars[i]
          if in_quotes
            if char == '"'
              if chars[i + 1] == '"'
                field << '"'
                i += 1
              else
                in_quotes = false
              end
            else
              field << char
            end
          else
            case char
            when '"' then in_quotes = true
            when ',' then row << field; field = +''
            when "\n" then row << field; rows << row; row = []; field = +''
            when "\r" then nil # игнорируем CR в CRLF
            else field << char
            end
          end
          i += 1
        end

        row << field unless field.empty? && row.empty?
        rows << row unless row.empty?
        rows
      end
    end
  end
end
