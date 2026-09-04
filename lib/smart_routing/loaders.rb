# frozen_string_literal: true

module SmartRouting
  # Чтение входных файлов с внятными ошибками вместо стектрейсов.
  module Loaders
    module_function

    def read_json(path, what:)
      raise InputError, "#{what} не найден: #{path}" unless File.file?(path)

      JSON.parse(File.read(path, encoding: 'bom|utf-8'))
    rescue JSON::ParserError => e
      raise InvalidDataError, "#{what} не является корректным JSON (#{path}): #{e.message}"
    end

    # @return [Array<Models::Operation>]
    def operations(path)
      data = read_json(path, what: 'Файл очереди')
      data = [data] if data.is_a?(Hash)
      raise InvalidDataError, "Очередь должна быть массивом заявок: #{path}" unless data.is_a?(Array)

      operations = data.each_with_index.map { |item, i| Models::Operation.from_json(item, index: i) }
      duplicates = operations.map(&:id).tally.select { |_, count| count > 1 }.keys
      unless duplicates.empty?
        raise InvalidDataError, "В очереди повторяются operation_id: #{duplicates.join(', ')}"
      end

      operations
    end

    # @return [Array<Models::Provider>]
    def providers(path, config)
      data = read_json(path, what: 'Файл провайдеров')
      list = data.is_a?(Hash) ? data['providers'] : data
      raise InvalidDataError, "Не найден массив providers в #{path}" unless list.is_a?(Array)
      raise InvalidDataError, "Список провайдеров пуст: #{path}" if list.empty?

      providers = list.each_with_index.map do |item, i|
        extension = config.provider_extension(item.is_a?(Hash) ? item['payment_system'].to_s : '')
        Models::Provider.from_json(item, extension: extension, index: i)
      end

      names = providers.map(&:name).tally.select { |_, count| count > 1 }.keys
      raise InvalidDataError, "Провайдеры дублируются: #{names.join(', ')}" unless names.empty?

      warn_missing_fallback(providers, config)
      providers
    end

    def snapshot_period(path)
      data = read_json(path, what: 'Файл провайдеров')
      return nil unless data.is_a?(Hash) && data['snapshot_at']

      Time.parse(data['snapshot_at']).strftime('%Y-%m-%d')
    rescue ArgumentError
      nil
    end

    def warn_missing_fallback(providers, config)
      name = config.fallback_provider
      return if name.nil?
      return if providers.any? { |p| p.name == name }

      warn "Предупреждение: fallback-провайдер #{name.inspect} отсутствует в снимке — " \
           'заявки без допустимых провайдеров завершатся ошибкой'
    end

    def write_json(path, data)
      dir = File.dirname(path)
      Dir.mkdir(dir) unless dir == '.' || Dir.exist?(dir)
      File.write(path, "#{JSON.pretty_generate(data)}\n")
      path
    end
  end
end
