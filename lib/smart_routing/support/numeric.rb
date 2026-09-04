# frozen_string_literal: true

module SmartRouting
  module Support
    # Мелкие числовые помощники, которые нужны и в стратегиях, и в отчёте.
    module Numeric
      module_function

      def clamp01(value)
        return 0.0 if value.nil?

        [[value.to_f, 0.0].max, 1.0].min
      end

      def round2(value)
        return nil if value.nil?

        (value.to_f * 100).round / 100.0
      end

      def pct(part, total)
        return 0.0 if total.nil? || total.to_f.zero?

        round2(part.to_f / total.to_f * 100)
      end

      def safe_div(part, total)
        return 0.0 if total.nil? || total.to_f.zero?

        part.to_f / total.to_f
      end

      # Min-max нормализация к [0, 1] для метрик без абсолютной шкалы
      # (позиция в каскаде, конверсия относительно конкурентов и т.п.).
      # Если разброс меньше epsilon — все кандидаты считаются равными (0.5),
      # чтобы шум не притворялся сигналом.
      def contrast(values, epsilon: 1e-9)
        return {} if values.empty?

        numbers = values.values.map(&:to_f)
        min = numbers.min
        max = numbers.max
        span = max - min
        return values.transform_values { 0.5 } if span <= epsilon

        values.transform_values { |v| (v.to_f - min) / span }
      end

      # То же самое, но меньшее значение = лучше (например, ошибка распределения).
      def contrast_inverse(values, epsilon: 1e-9)
        contrast(values, epsilon: epsilon).transform_values { |v| 1.0 - v }
      end
    end
  end
end
