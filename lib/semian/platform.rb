class Semian
  # Determines if Semian supported on the current platform.
  def self.supported_platform?
    /linux/.matches(RUBY_PLATFORM)
  end
end
