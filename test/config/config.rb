require 'yaml'

class Config
  CONFIG_FILE = File.expand_path('../hosts.yml', __FILE__)

  class << self
    def host_for(service)
      config_for(service).fetch('host') 
    end

    def port_for(service)
      config_for(service).fetch('port') 
    end

    def toxic_port_for(service)
      config_for(service).fetch('toxic_port') 
    end

    private

    def config_for(service)
      @yaml ||= YAML.load_file(CONFIG_FILE)
      @yaml.fetch(service) 
    end
  end
end
