# frozen_string_literal: true

module RactorHelper
  private

  def ractor_value(ractor)
    ractor.respond_to?(:value) ? ractor.value : ractor.take
  end
end
