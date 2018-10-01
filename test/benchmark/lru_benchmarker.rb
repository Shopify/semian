# Benchmarks the usage of an LRUHash during the set operation.
# To make sure we are cleaning resources, MINIMUM_TIME_IN_LRU needs
# to be set to 0
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../test', __FILE__)
require 'thin'
require 'benchmark'
require 'benchmark/ips'
require 'benchmark/memory'
require 'semian'
require 'semian/net_http'
require 'toxiproxy'
require 'yaml'
require 'byebug'
require 'minitest'

class LRUBenchmarker
  def run_ips_benchmark
    Benchmark.ips do |x|
      [500, 1000, 2500, 5000].each do |nb_resoures|
        x.report("#{nb_resoures} resources ") { create_resources(nb_resoures) }
      end
    end
  end

  def run_memory_benchmark
    Benchmark.memory do |x|
      [500, 1000].each do |nb_resoures|
        x.report("Memory usage for #{nb_resoures} resources ") { create_resources(nb_resoures) }
      end
    end
  end

  private

  def create_resources(number_of_resources)
    reset_semian_resource
    number_of_resources.times do |i|
      create_request(i)
    end
  end

  def create_request(i)
    # Creates a new resource and will randomly
    # make it a success or a failure
    random = rand(1...100)
    if random >= 0 && random <= 50
      Semian.register("testing_#{i}", bulkhead: true, tickets: 1, error_threshold: 2, error_timeout: 5, success_threshold: 1)
    else
      Semian.register("testing_#{i}", bulkhead: false, tickets: 1, error_threshold: 2, error_timeout: 5, success_threshold: 1)
    end
  end

  def reset_semian_resource
    Semian.reset!
  end
end

benchmarker = LRUBenchmarker.new
benchmarker.run_ips_benchmark
benchmarker.run_memory_benchmark
