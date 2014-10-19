class Semian
  # Determines if Semian supported on the current platform.
  def self.supported_platform?
    RUBY_PLATFORM.end_with?('-linux')
  end
end
