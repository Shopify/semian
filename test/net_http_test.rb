require 'test_helper'
require 'semian/net_http'
require 'thin'

class TestNetHTTP < MiniTest::Unit::TestCase
  class RackServer
    def self.call(env)
      response_code = env['REQUEST_URI'].delete("/")
      response_code = '200' if response_code == ""
      [response_code, {'Content-Type' => 'text/html'}, ['Success']]
    end
  end

  def setup
    # create a simple rack server so we can use toxiproxy
    start_server_singleton
    Semian["http_localhost_41234"].reset if Semian["http_localhost_41234"]
    Semian["http_localhost_41235"].reset if Semian["http_localhost_41235"]
    Semian.destroy('http_localhost_41234')
    Semian.destroy('http_localhost_41235')
    @proxy = Toxiproxy[:semian_test_net_http]
  end

  def test_server_up_and_toxiproxy_working
    uri = URI('http://localhost:41234/200')
    assert_equal "Success", Net::HTTP.get(uri)

    uri = URI('http://localhost:41235/200')
    @proxy.downstream(:latency, latency: 300).apply do
      time = Time.now
      Net::HTTP.get(uri)

      time_diff = Time.now - time
      assert time_diff >= 0.3
    end
  end

  def test_semian_identifier
    Net::HTTP.start("localhost", 41_235) do |http|
      assert_equal "http_localhost_41235", http.semian_identifier
    end
  end

  def test_trigger_open
    open_circuit!
    uri = URI('http://localhost:41235/200')
    assert_raises Net::CircuitOpenError do
      Net::HTTP.get(uri)
    end
  end

  def test_trigger_close_after_open
    open_circuit!
    close_circuit!
  end

  def test_blockheads_tickets_are_working
    threads = []
    ticket_count = Net::HTTP.new("localhost", 41_235).raw_semian_options[:tickets]

    @proxy.downstream(:latency, latency: 500).apply do
      uri = URI('http://localhost:41235/200')
      (ticket_count).times do
        threads << Thread.new do
          Net::HTTP.get(uri)
        end
      end
      sleep 0.3
      assert_raises Net::ResourceBusyError do
        Net::HTTP.get(uri)
      end

      threads.each(&:join)
    end
  end

  def test_get_type_1_is_protected
    open_circuit!
    assert_raises Net::CircuitOpenError do
      Net::HTTP.get(URI('http://localhost:41235/200'))
    end
  end

  def test_get_type_2_is_protected
    open_circuit!
    assert_raises Net::CircuitOpenError do
      http = Net::HTTP.new("localhost", "41235")
      http.get("/")
    end
  end

  def test_get_type_3_is_protected
    open_circuit!
    assert_raises Net::CircuitOpenError do
      uri = URI('http://localhost:41235/200')
      Net::HTTP.get_response(uri)
    end
  end

  def test_post_type_1_is_protected
    open_circuit!
    assert_raises Net::CircuitOpenError do
      uri = URI('http://localhost:41235/200')
      Net::HTTP.post_form(uri, 'q' => 'ruby', 'max' => '50')
    end
  end

  def test_http_start_and_inner_methods_are_protected
    open_circuit!

    uri = URI('http://localhost:41235/200')
    assert_raises Net::CircuitOpenError do
      Net::HTTP.start(uri.host, uri.port) do |_|
      end
    end

    close_circuit!
    Net::HTTP.start(uri.host, uri.port) do |http|
      open_circuit!
      assert_raises Net::CircuitOpenError do
        request = Net::HTTP::Get.new uri
        http.request(request)
      end
      assert_raises Net::CircuitOpenError do
        request = Net::HTTP::Post.new uri
        http.request(request)
      end
      # and so on...
    end
  end

  def test_custom_raw_semian_options_work
    orig_semian_options = Semian::NetHTTP.raw_semian_options
    yaml_sample_config = {}
    yaml_sample_config["development"] = {}
    yaml_sample_config["development"]["http_default"] = {"tickets" => 1,
                                                         "success_threshold" => 1,
                                                         "error_threshold" => 3,
                                                         "error_timeout" => 10}
    yaml_sample_config["development"]["http_localhost_41235"] = {"tickets" => 1,
                                                                 "success_threshold" => 1,
                                                                 "error_threshold" => 3,
                                                                 "error_timeout" => 10}
    sample_env = "development"
    Semian::NetHTTP.raw_semian_options = proc do |semian_identifier|
      if !yaml_sample_config[sample_env].key?(semian_identifier)
        yaml_sample_config[sample_env]["http_default"]
      else
        yaml_sample_config[sample_env][semian_identifier]
      end
    end
    Net::HTTP.start("localhost", 41_235) do |http|
      assert_equal yaml_sample_config["development"][http.semian_identifier], http.raw_semian_options
    end
    Net::HTTP.start("localhost", 41_234) do |http|
      assert_equal yaml_sample_config["development"]["http_default"], http.raw_semian_options
    end
    assert_equal yaml_sample_config["development"]["http_default"], Semian::NetHTTP.raw_semian_options
  ensure
    Semian::NetHTTP.raw_semian_options = orig_semian_options
  end

  def open_circuit!
    Net::HTTP.start("localhost", 41_235) do |http|
      http.read_timeout = 0.1
      uri = URI('http://localhost:41235/200')

      http.raw_semian_options[:error_threshold].times do
        # Cause error error_threshold times so circuit opens
        @proxy.downstream(:latency, latency: 150).apply do
          request = Net::HTTP::Get.new(uri)
          assert_raises Net::ReadTimeout do
            http.request(request)
          end
        end
      end
    end
  end

  def close_circuit!
    http = Net::HTTP.new("localhost", 41_235)
    Timecop.travel(http.raw_semian_options[:error_timeout] + 1)
    # Cause successes success_threshold times so circuit closes
    http.raw_semian_options[:success_threshold].times do
      http.get("/200")
    end
  end

  class << self
    attr_accessor :server_thread
  end

  def start_server_singleton
    return if self.class.server_thread
    self.class.server_thread = Thread.new do
      Thin::Logging.silent = true
      Thin::Server.start('localhost', 41_234, RackServer)
    end
    poll_until_ready(port: 41_234, time_to_wait: 1)
  end

  def poll_until_ready(port: 41_234, time_to_wait: 1)
    start_time = Time.now.to_i
    begin
      TCPSocket.new('127.0.0.1', port).close
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      if Time.now.to_i > start_time + time_to_wait
        raise "Couldn't reach the service on port #{port} after #{time_to_wait}s"
      else
        retry
      end
    end
  end

  def after_tests
    self.class.server_thread.kill
  end
end
