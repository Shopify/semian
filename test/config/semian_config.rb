# frozen_string_literal: true

require "yaml"

class SemianConfig
  CONFIG_FILE = File.expand_path("../hosts.yml", __FILE__)

  class << self
    def [](service)
      all.fetch(service)
    end

    def all
      @entries ||= YAML.load_file(CONFIG_FILE)
    end
  end
end
