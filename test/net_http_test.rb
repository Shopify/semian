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

  PORT = 31_050
  TOXIC_PORT = PORT + 1

  DEFAULT_SEMIAN_OPTIONS = {
    tickets: 3,
    success_threshold: 1,
    error_threshold: 3,
    error_timeout: 10,
  }

  def test_semian_identifier
    with_server do
      Net::HTTP.start("localhost", TOXIC_PORT) do |http|
        assert_equal "http_localhost_#{TOXIC_PORT}", http.semian_identifier
      end
    end
  end

  def test_trigger_open
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      with_server do
        open_circuit!
        uri = URI("http://localhost:#{TOXIC_PORT}/200")
        assert_raises Net::CircuitOpenError do
          Net::HTTP.get(uri)
        end
      end
    end
  end

  def test_trigger_close_after_open
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      with_server do
        open_circuit!
        close_circuit!
      end
    end
  end

  def test_bulkheads_tickets_are_working
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      with_server do
        ticket_count = Net::HTTP.new("localhost", TOXIC_PORT).raw_semian_options[:tickets]
        m = Monitor.new
        acquired_count = 0
        ticket_count.times do
          threads << Thread.new do
            http = Net::HTTP.new("localhost", "#{TOXIC_PORT}")
            http.acquire_semian_resource(adapter: :nethttp, scope: :connection) do
              m.synchronize do
                acquired_count += 1
              end
              sleep
            end
          end
        end

        Thread.new do
          sleep(1) until acquired_count == ticket_count
          http = Net::HTTP.new("localhost", "#{TOXIC_PORT}")
          assert_raises Net::ResourceBusyError do
            http.get("/")
          end
          threads.each(&:join)
        end
      end
    end
  end

  def test_get_is_protected
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      with_server do
        open_circuit!
        assert_raises Net::CircuitOpenError do
          Net::HTTP.get(URI("http://localhost:#{TOXIC_PORT}/200"))
        end
      end
    end
  end

  def test_instance_get_is_protected
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      with_server do
        open_circuit!
        assert_raises Net::CircuitOpenError do
          http = Net::HTTP.new("localhost", "#{TOXIC_PORT}")
          http.get("/")
        end
      end
    end
  end

  def test_get_response_is_protected
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      with_server do
        open_circuit!
        assert_raises Net::CircuitOpenError do
          uri = URI("http://localhost:#{TOXIC_PORT}/200")
          Net::HTTP.get_response(uri)
        end
      end
    end
  end

  def test_post_type_1_is_protected
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      with_server do
        open_circuit!
        assert_raises Net::CircuitOpenError do
          uri = URI("http://localhost:#{TOXIC_PORT}/200")
          Net::HTTP.post_form(uri, 'q' => 'ruby', 'max' => '50')
        end
      end
    end
  end

  def test_http_start_and_inner_methods_are_protected
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      with_server do
        open_circuit!

        uri = URI("http://localhost:#{TOXIC_PORT}/200")
        assert_raises Net::CircuitOpenError do
          Net::HTTP.start(uri.host, uri.port) {}
        end

        close_circuit!
        Net::HTTP.start(uri.host, uri.port) do |http|
          open_circuit!
          get_subclasses(Net::HTTPRequest).each do |action|
            assert_raises(Net::CircuitOpenError, "#{action.name} did not raise a Net::CircuitOpenError") do
              request = action.new uri
              http.request(request)
            end
          end
        end
      end
    end
  end

  def test_custom_raw_semian_options_work
    with_server do
      semian_config = {}
      semian_config["development"] = {}
      semian_config["development"]["http_default"] =
        {"tickets" => 1,
         "success_threshold" => 1,
         "error_threshold" => 3,
         "error_timeout" => 10}
      semian_config["development"]["http_localhost_#{TOXIC_PORT}"] =
        {"tickets" => 1,
         "success_threshold" => 1,
         "error_threshold" => 3,
         "error_timeout" => 10}
      sample_env = "development"

      semian_options_proc = proc do |semian_identifier|
        if !semian_config[sample_env].key?(semian_identifier)
          semian_config[sample_env]["http_default"]
        else
          semian_config[sample_env][semian_identifier]
        end
      end

      with_semian_options(semian_options_proc) do
        Net::HTTP.start("localhost", TOXIC_PORT) do |http|
          assert_equal semian_config["development"][http.semian_identifier], http.raw_semian_options
        end
        Net::HTTP.start("localhost", PORT) do |http|
          assert_equal semian_config["development"]["http_default"], http.raw_semian_options
        end
        assert_equal semian_config["development"]["http_default"],
                     Semian::NetHTTP.retrieve_semian_options_by_identifier("http_default")
      end
    end
  end

  def test_custom_raw_semian_options_can_disable
    with_server do # disabled if nil
      semian_options_proc = proc { nil }
      with_semian_options(semian_options_proc) do
        http = Net::HTTP.new("localhost", "#{TOXIC_PORT}")
        assert_equal false, http.enabled?
      end
    end

    with_server do # disabled if key not found
      semian_config = {}
      semian_config["development"] = {}
      semian_config["development"]["http_localhost_#{TOXIC_PORT}"] =
        {"tickets" => 1,
         "success_threshold" => 1,
         "error_threshold" => 3,
         "error_timeout" => 10}
      sample_env = "development"

      semian_options_proc = proc do |semian_identifier|
        semian_config[sample_env][semian_identifier]
      end
      with_semian_options(semian_options_proc) do
        http = Net::HTTP.new("localhost", "#{TOXIC_PORT}")
        assert_equal true, http.enabled?

        http = Net::HTTP.new("localhost", "#{TOXIC_PORT + 100}")
        assert_equal false, http.enabled?
      end
    end
  end

  def test_adding_custom_errors_work
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      with_server do
        with_custom_errors([::OpenSSL::SSL::SSLError]) do
          http = Net::HTTP.new("localhost", TOXIC_PORT)
          assert http.resource_exceptions.include?(::OpenSSL::SSL::SSLError)
        end
      end
    end
  end

  def test_multiple_different_endpoints_and_ports_are_tracked_differently
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      ports = [PORT + 100, PORT + 200]
      ports.each do |port|
        Semian["http_localhost_#{port}"].reset if Semian["http_localhost_#{port}"]
        Semian["http_localhost_#{port + 1}"].reset if Semian["http_localhost_#{port + 1}"]
        Semian.destroy('http_localhost_#{port}')
        Semian.destroy('http_localhost_#{port + 1}')
        with_server(port: port, reset_semian_state: false) do
          with_toxic(upstream_port: port, toxic_port: port + 1) do |name|
            open_circuit!(toxic_port: port + 1, toxic_name: name)
            close_circuit!(toxic_port: port + 1)
          end
        end
      end
      with_server(port: PORT, reset_semian_state: false) do
        open_circuit!
        Net::HTTP.get(URI("http://127.0.0.1:#{PORT}/")) # different endpoint, should not raise errors
      end
    end
  end

  def test_persistent_state_after_server_restart
    with_semian_options(DEFAULT_SEMIAN_OPTIONS) do
      port = PORT + 100
      with_server(port: port) do
        with_toxic(upstream_port: port, toxic_port: port + 1) do |name|
          open_circuit!(toxic_port: port + 1, toxic_name: name)
        end
      end
      with_server(port: port, reset_semian_state: false) do
        with_toxic(upstream_port: port, toxic_port: port + 1) do |_|
          assert_raises Net::CircuitOpenError do
            Net::HTTP.get(URI("http://localhost:#{port + 1}/200"))
          end
        end
      end
    end
  end

  private

  def with_semian_options(options)
    orig_semian_options = Semian::NetHTTP.raw_semian_options
    Semian::NetHTTP.raw_semian_options = options
    yield
  ensure
    Semian::NetHTTP.raw_semian_options = orig_semian_options
  end

  def with_custom_errors(errors)
    orig_errors = Semian::NetHTTP.exceptions
    errors.each do |error|
      Semian::NetHTTP.exceptions << error
    end
    yield
  ensure
    Semian::NetHTTP.exceptions = orig_errors
  end

  def get_subclasses(klass)
    ObjectSpace.each_object(klass.singleton_class).to_a - [klass]
  end

  def open_circuit!(toxic_port: TOXIC_PORT, toxic_name: "semian_test_net_http")
    Net::HTTP.start("localhost", toxic_port) do |http|
      http.read_timeout = 0.1
      uri = URI("http://localhost:#{toxic_port}/200")
      http.raw_semian_options[:error_threshold].times do
        # Cause error error_threshold times so circuit opens
        Toxiproxy[toxic_name].downstream(:latency, latency: 150).apply do
          request = Net::HTTP::Get.new(uri)
          assert_raises Net::ReadTimeout do
            http.request(request)
          end
        end
      end
    end
  end

  def close_circuit!(toxic_port: TOXIC_PORT)
    http = Net::HTTP.new("localhost", toxic_port)
    Timecop.travel(http.raw_semian_options[:error_timeout])
    # Cause successes success_threshold times so circuit closes
    http.raw_semian_options[:success_threshold].times do
      response = http.get("/200")
      assert(200, response.code)
    end
  end

  def with_server(port: PORT, reset_semian_state: true)
    server_thread = Thread.new do
      Thin::Logging.silent = true
      Thin::Server.start('localhost', port, RackServer)
    end
    poll_until_ready(port: port)
    if reset_semian_state
      Semian["http_localhost_#{port}"].reset if Semian["http_localhost_#{port}"]
      Semian["http_localhost_#{port + 1}"].reset if Semian["http_localhost_#{port + 1}"]
      Semian.destroy('http_localhost_#{port}')
      Semian.destroy('http_localhost_#{port + 1}')
    end
    @proxy = Toxiproxy[:semian_test_net_http]
    yield
  ensure
    server_thread.kill
    poll_until_gone(port: PORT)
  end

  def with_toxic(upstream_port: PORT, toxic_port: upstream_port + 1)
    old_proxy = @proxy
    name = "semian_test_net_http_#{upstream_port}_#{toxic_port}"
    Toxiproxy.populate([
      {
        name: name,
        upstream: "localhost:#{upstream_port}",
        listen: "localhost:#{toxic_port}",
      },
    ])
    @proxy = Toxiproxy[name]
    yield(name)
  ensure
    @proxy = old_proxy
    begin
      Toxiproxy[name].destroy
    rescue nil
    end
  end

  def poll_until_ready(port: PORT, time_to_wait: 2)
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

  def poll_until_gone(port: PORT, time_to_wait: 2)
    start_time = Time.now.to_i
    loop do
      if Time.now.to_i > start_time + time_to_wait
        raise "Could still reach the service on port #{port} after #{time_to_wait}s"
      end
      begin
        TCPSocket.new("127.0.0.1", port).close
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        return true
      end
    end
  end
end
