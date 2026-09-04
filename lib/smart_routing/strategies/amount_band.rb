# frozen_string_literal: true

module SmartRouting
  module Strategies
    # Стратегия 4: маршрутизация по диапазону суммы чека.
    #
    # Важное отличие от hard-constraint AmountRange: там сумма определяет
    # допуск, здесь — предпочтение. Провайдер вне «своего» диапазона
    # остаётся допустимым, просто получает меньший балл.
    class AmountBand < Base
      def self.key = 'amount_band'
      def self.title = 'Диапазон суммы чека'

      def score(candidates, operation, _pool)
        band = band_for(operation.amount)
        return zeroed(candidates) if band.nil?

        preferred = Array(band['prefer'])
        return zeroed(candidates) if preferred.empty?

        candidates.to_h do |candidate|
          [candidate.name, preferred.include?(candidate.name) ? match_score : miss_score]
        end
      end

      def explain(provider, operation, _pool)
        band = band_for(operation.amount)
        return "для суммы #{format('%.0f', operation.amount)} ₽ диапазон не задан" if band.nil?

        preferred = Array(band['prefer'])
        verdict = preferred.include?(provider.name) ? 'профильный' : 'вне профиля'
        "диапазон #{band_label(band)} → #{preferred.join(', ')}; #{provider.name} #{verdict}"
      end

      private

      def band_for(amount)
        config.amount_bands.find do |band|
          from = band['from']
          to = band['to']
          (from.nil? || amount >= from.to_f) && (to.nil? || amount <= to.to_f)
        end
      end

      def band_label(band)
        from = band['from'] ? format('%.0f', band['from'].to_f) : '0'
        to = band['to'] ? format('%.0f', band['to'].to_f) : '∞'
        "#{from}–#{to}"
      end

      def match_score = (config.profile.dig('amount_band', 'match_score') || 1.0).to_f
      def miss_score = (config.profile.dig('amount_band', 'miss_score') || 0.25).to_f
    end
  end
end
