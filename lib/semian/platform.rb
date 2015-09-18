module Semian
  # Determines if Semian supported on the current platform.
  def self.sysv_semaphores_supported?
    /linux|darwin/.match(RUBY_PLATFORM)
  end
end
