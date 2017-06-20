require 'yaml'

class Config
  CONFIG_FILE = File.expand_path('../hosts.yml', __FILE__)

  class << self
    def [](service)
      all.fetch(service)
    end

    def all
      @entries ||= YAML.load_file(CONFIG_FILE)
    end
  end

  module Helpers
    class << self
      def included(clazz)
        clazz.extend(Helpers)
      end

      def define_helper_methods(service)
        keys = Config[service].keys
        keys.each { |attr| define_helper_method(service, attr) }
      end

      private

      def define_helper_method(service, attribute)
        self.__send__(:define_method, "#{service}_#{attribute}") do
          Config[service].fetch(attribute)
        end
      end
    end

    Config.all.keys.each { |service| define_helper_methods(service) }
  end
end
