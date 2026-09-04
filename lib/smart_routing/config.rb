# frozen_string_literal: true

module SmartRouting
  # Конфигурация роутера: config/routing.yml.
  #
  # Вся бизнес-настройка (веса стратегий, включённые hard-constraints,
  # диапазоны сумм, фин. обязательства, лимиты интенсивности) живёт в YAML.
  # Код читает только ключи — чтобы поменять правило, менять Ruby не нужно.
  class Config
    DEFAULT_PATH = File.join(SmartRouting::ROOT, 'config', 'routing.yml')

    attr_reader :raw, :profile_name, :profile, :source_path

    def self.load(path = DEFAULT_PATH, profile: nil)
      path ||= DEFAULT_PATH
      raise InputError, "Конфиг не найден: #{path}" unless File.file?(path)

      raw = begin
        YAML.safe_load(File.read(path), aliases: true) || {}
      rescue Psych::SyntaxError => e
        raise ConfigError, "Некорректный YAML в #{path}: #{e.message}"
      end
      new(raw, profile: profile, source_path: path)
    end

    def initialize(raw, profile: nil, source_path: nil)
      @raw = deep_stringify(raw)
      @source_path = source_path
      @profile_name = profile || @raw['active_profile'] || 'balanced'
      profiles = @raw['profiles'] || {}
      unless profiles.key?(@profile_name)
        raise ConfigError,
              "Профиль #{@profile_name.inspect} не найден. Доступны: #{profiles.keys.sort.join(', ')}"
      end

      @profile = deep_merge(@raw['defaults'] || {}, profiles[@profile_name] || {})
      validate!
    end

    def profile_description
      profile['description'].to_s
    end

    def weights
      (profile['weights'] || {}).transform_values(&:to_f).reject { |_, v| v <= 0 }
    end

    def enabled_constraints
      (profile['constraints'] || {}).select { |_, v| v.nil? || v['enabled'] != false }.keys
    end

    def constraint_options(name)
      (profile.dig('constraints', name) || {})
    end

    def provider_extension(payment_system)
      base = profile.dig('provider_defaults') || {}
      override = profile.dig('provider_overrides', payment_system) || {}
      deep_merge(base, override)
    end

    def amount_bands
      Array(profile['amount_bands'])
    end

    def fallback_provider
      profile['fallback_provider']
    end

    def max_attempts
      (profile['max_attempts'] || 3).to_i
    end

    def tie_break_epsilon
      (profile['tie_break_epsilon'] || 0.02).to_f
    end

    # Явный приоритет политик: чем раньше в списке, тем весомее при ничье.
    def conflict_order
      order = Array(profile['conflict_order'])
      order.empty? ? weights.keys : order
    end

    def simulation
      profile['simulation'] || {}
    end

    def history_blend
      (profile['history_blend'] || 0.0).to_f
    end

    def to_h
      { 'profile' => profile_name, 'description' => profile_description }.merge(profile)
    end

    private

    def validate!
      known = Strategies::Registry.keys
      unknown = weights.keys - known
      unless unknown.empty?
        raise ConfigError, "Неизвестные стратегии в weights: #{unknown.join(', ')}. Доступны: #{known.join(', ')}"
      end
      raise ConfigError, 'weights пуст: нечем ранжировать кандидатов' if weights.empty?

      unknown_constraints = enabled_constraints - Constraints::Registry.keys
      unless unknown_constraints.empty?
        raise ConfigError,
              "Неизвестные constraints: #{unknown_constraints.join(', ')}. " \
              "Доступны: #{Constraints::Registry.keys.join(', ')}"
      end

      bad_order = conflict_order - known
      return if bad_order.empty?

      raise ConfigError, "conflict_order ссылается на неизвестные стратегии: #{bad_order.join(', ')}"
    end

    def deep_merge(base, override)
      base.merge(override) do |_key, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
      end
    end

    def deep_stringify(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s, deep_stringify(v)] }
      when Array then value.map { |v| deep_stringify(v) }
      else value
      end
    end
  end
end
