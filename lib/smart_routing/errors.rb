# frozen_string_literal: true

module SmartRouting
  # Базовая ошибка домена. Всё, что мы умеем объяснить пользователю CLI,
  # наследуется от неё — CLI печатает такие ошибки без стектрейса.
  class Error < StandardError; end

  # Файл не найден / не читается.
  class InputError < Error; end

  # Файл прочитан, но содержимое не соответствует ожидаемой схеме.
  class InvalidDataError < Error; end

  # Ошибка в config/routing.yml: неизвестная стратегия, битые веса и т.п.
  class ConfigError < Error; end

  # Пул провайдеров пуст даже с учётом self-provider.
  class NoProviderError < Error; end
end
