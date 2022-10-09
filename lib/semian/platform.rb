# frozen_string_literal: true

module Semian
  extend self

  # Determines if Semian supported on the current platform.
  def sysv_semaphores_supported?
    /linux/.match(RUBY_PLATFORM)
  end

  def semaphores_enabled?
    !disabled? && sysv_semaphores_supported?
  end

  def disabled?
    ENV.key?("SEMIAN_SEMAPHORES_DISABLED") || ENV.key?("SEMIAN_DISABLED")
  end
end
