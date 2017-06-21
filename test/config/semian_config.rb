require 'yaml'

class SemianConfig
  CONFIG_FILE = File.expand_path('../hosts.yml', __FILE__)

  class << self
    def [](service)
      all.fetch(service)
    end

    def all
      @entries ||= begin
        entries = YAML.load_file(CONFIG_FILE)
        flatten_keys(entries)
      end
    end

    private

    def flatten_keys(entries, object = {}, parent_key = '')
      entries.each_with_object(object) do |(key, value), hash|
        next flatten_keys(value, hash, key) if value.is_a?(Hash)

        hash["#{parent_key}_#{key}"] = value
        hash
      end
    end
  end
end
