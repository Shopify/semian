$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../test', __FILE__)
require 'thin'
require 'benchmark'
require 'benchmark/ips'
require 'memory_profiler'
require 'semian'
require 'semian/net_http'
require 'toxiproxy'
require 'yaml'
require 'byebug'
require 'minitest'
require 'helpers/net_helper'

class SemianConfig
  CONFIG_FILE = File.expand_path('../../../test/config/hosts.yml', __FILE__)

  class << self
    def [](service)
      all.fetch(service)
    end

    def all
      @entries ||= YAML.load_file(CONFIG_FILE)
    end
  end
end

class RackServer
  def self.call(env)
    response_code = env['REQUEST_URI'].delete("/")
    response_code = '200' if response_code == ""
    [response_code, {'Content-Type' => 'text/html'}, ['Success']]
  end
end

class Benchmarker
  include NetHelper
  DEFAULT_SEMIAN_OPTIONS = {
    tickets: 3,
    success_threshold: 1,
    error_threshold: 3,
    error_timeout: 10,
  }.freeze

  DEFAULT_SEMIAN_CONFIGURATION = proc do |host, port|
    next nil if host == SemianConfig['toxiproxy_upstream_host'] && port == SemianConfig['toxiproxy_upstream_port'] # disable if toxiproxy
    DEFAULT_SEMIAN_OPTIONS.merge(name: "#{host}_#{port}")
  end

  def initialize
    run_benchmark_resources
  end

  def run_benchmark_resources
    run_ips
  end

  def run_ips
    Benchmark.ips do |x|
      [500, 1000, 2500, 5000].each do |nb_resoures|
        x.report("#{nb_resoures} resources ") { lru_resource(nb_resoures) }
      end
      x.compare!
    end
  end

  def lru_resource(number_of_resources)
    @request_time = []
    reset_semian_resource
    with_semian_configuration do
      with_server(ports: [3000], reset_semian_state: false) do |host, port|
        number_of_resources.times do |i|
          create_request(host, port, i)
        end
      end
    end
    puts "Average = #{@request_time.reduce(:+) / @request_time.size.to_f}"
  end

  def create_request(host, port, i)
    random = rand(1...100)
    average_time = average do
      if random >= 0 && random <= 50
        Net::HTTP.get(URI("http://#{SemianConfig['toxiproxy_upstream_host']}:3000/"))
      else
        with_toxic(hostname: host, upstream_port: 3001, toxic_port: port + i) do
          Net::HTTP.get(URI("http://#{host}:#{port + i + 1}/"))
        end
      end
    end
    @request_time.push(average_time)
  end

  private

  def average
    bench_time = Benchmark.measure do
      yield
    end
    bench_time.real
  end

  def with_semian_configuration(options = DEFAULT_SEMIAN_CONFIGURATION)
    orig_semian_options = Semian::NetHTTP.semian_configuration
    Semian::NetHTTP.instance_variable_set(:@semian_configuration, nil)
    mutated_objects = {}
    Semian::NetHTTP.send(:alias_method, :orig_semian_resource, :semian_resource)
    Semian::NetHTTP.send(:alias_method, :orig_raw_semian_options, :raw_semian_options)
    Semian::NetHTTP.send(:define_method, :semian_resource) do
      mutated_objects[self] = [@semian_resource, @raw_semian_options] unless mutated_objects.key?(self)
      orig_semian_resource
    end
    Semian::NetHTTP.send(:define_method, :raw_semian_options) do
      mutated_objects[self] = [@semian_resource, @raw_semian_options] unless mutated_objects.key?(self)
      orig_raw_semian_options
    end

    Semian::NetHTTP.semian_configuration = options
    yield
  ensure
    Semian::NetHTTP.instance_variable_set(:@semian_configuration, nil)
    Semian::NetHTTP.semian_configuration = orig_semian_options
    Semian::NetHTTP.send(:alias_method, :semian_resource, :orig_semian_resource)
    Semian::NetHTTP.send(:alias_method, :raw_semian_options, :orig_raw_semian_options)
    Semian::NetHTTP.send(:undef_method, :orig_semian_resource, :orig_raw_semian_options)
    mutated_objects.each do |instance, (res, opt)| # Sadly, only way to fully restore cached properties
      instance.instance_variable_set(:@semian_resource, res)
      instance.instance_variable_set(:@raw_semian_options, opt)
    end
  end

  def reset_semian_resource
    Semian.reset!
  end
end

Benchmarker.new
