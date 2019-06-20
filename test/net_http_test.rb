require 'test_helper'
require 'semian/net_http'

class TestNetHTTP < Minitest::Test
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

  def test_semian_identifier
    with_server do
      with_semian_configuration do
        Net::HTTP.start(SemianConfig['toxiproxy_upstream_host'], SemianConfig['http_toxiproxy_port']) do |http|
          assert_equal "nethttp_#{SemianConfig['toxiproxy_upstream_host']}_#{SemianConfig['http_toxiproxy_port']}", http.semian_identifier
        end
      end
    end
  end

  def test_changes_timeout_when_half_open_and_configured
    http = Net::HTTP.new(SemianConfig['toxiproxy_upstream_host'], SemianConfig['http_toxiproxy_port'])
    expected_read_timeout = http.read_timeout
    expected_open_timeout = http.open_timeout
    options = proc do |host, port|
      {
        tickets: 3,
        success_threshold: 2,
        error_threshold: 2,
        error_timeout: 10,
        open_circuit_server_errors: true,
        name: "#{host}_#{port}",
        half_open_resource_timeout: 1,
      }
    end

    with_semian_configuration(options) do
      with_server do
        Toxiproxy['semian_test_net_http'].downstream(:latency, latency: 2000).apply do
          http.get('/200')
        end

        half_open_cicuit!

        Toxiproxy['semian_test_net_http'].downstream(:latency, latency: 2000).apply do
          assert_raises Net::ReadTimeout do
            http.get('/200')
          end
        end
      end
    end

    assert_equal expected_read_timeout, http.read_timeout
    assert_equal expected_open_timeout, http.open_timeout
  end

  def test_trigger_open
    with_semian_configuration do
      with_server do
        open_circuit!

        uri = URI("http://#{SemianConfig['toxiproxy_upstream_host']}:#{SemianConfig['http_toxiproxy_port']}/200")
        exception = assert_raises Net::CircuitOpenError do
          Net::HTTP.get(uri)
        end
        assert_equal "Net::ReadTimeout", exception.cause.to_s
      end
    end
  end

  def test_trigger_close_after_open
    with_semian_configuration do
      with_server do
        open_circuit!
        close_circuit!
      end
    end
  end

  def test_bulkheads_tickets_are_working
    options = proc do |host, port|
      {
        tickets: 2,
        success_threshold: 1,
        error_threshold: 3,
        error_timeout: 10,
        name: "#{host}_#{port}",
      }
    end
    with_semian_configuration(options) do
      with_server do
        http_1 = Net::HTTP.new(SemianConfig['toxiproxy_upstream_host'], SemianConfig['http_toxiproxy_port'])
        http_1.semian_resource.acquire do
          http_2 = Net::HTTP.new(SemianConfig['toxiproxy_upstream_host'], SemianConfig['http_toxiproxy_port'])
          http_2.semian_resource.acquire do
            assert_raises Net::ResourceBusyError do
              Net::HTTP.get(URI("http://#{SemianConfig['toxiproxy_upstream_host']}:#{SemianConfig['http_toxiproxy_port']}/"))
            end
          end
        end
      end
    end
  end

  def test_get_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!
        assert_raises Net::CircuitOpenError do
          Net::HTTP.get(URI("http://#{SemianConfig['toxiproxy_upstream_host']}:#{SemianConfig['http_toxiproxy_port']}/200"))
        end
      end
    end
  end

  def test_instance_get_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!

        assert_raises Net::CircuitOpenError do
          http = Net::HTTP.new(SemianConfig['toxiproxy_upstream_host'], SemianConfig['http_toxiproxy_port'])
          http.get("/")
        end
      end
    end
  end

  def test_get_response_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!

        assert_raises Net::CircuitOpenError do
          uri = URI("http://#{SemianConfig['toxiproxy_upstream_host']}:#{SemianConfig['http_toxiproxy_port']}/200")
          Net::HTTP.get_response(uri)
        end
      end
    end
  end

  def test_post_form_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!

        assert_raises Net::CircuitOpenError do
          uri = URI("http://#{SemianConfig['toxiproxy_upstream_host']}:#{SemianConfig['http_toxiproxy_port']}/200")
          Net::HTTP.post_form(uri, 'q' => 'ruby', 'max' => '50')
        end
      end
    end
  end

  def test_http_start_method_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!

        uri = URI("http://#{SemianConfig['toxiproxy_upstream_host']}:#{SemianConfig['http_toxiproxy_port']}/200")
        assert_raises Net::CircuitOpenError do
          Net::HTTP.start(uri.host, uri.port) {}
        end
        close_circuit!
      end
    end
  end

  def test_http_action_request_inside_start_methods_are_protected
    with_semian_configuration do
      with_server do
        uri = URI("http://#{SemianConfig['toxiproxy_upstream_host']}:#{SemianConfig['http_toxiproxy_port']}/200")
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

  def test_custom_raw_semian_options_work_with_lookup
    with_server do
      toxiproxy_upstream_host = SemianConfig['toxiproxy_upstream_host']
      http_toxiproxy_port = SemianConfig['http_toxiproxy_port']

      semian_config = {}
      semian_config["development"] = {}
      semian_config["development"]["nethttp_#{toxiproxy_upstream_host}_#{http_toxiproxy_port}"] = DEFAULT_SEMIAN_OPTIONS
      sample_env = "development"

      semian_configuration_proc = proc do |host, port|
        semian_identifier = "nethttp_#{host}_#{port}"
        semian_config[sample_env][semian_identifier].merge(name: "#{host}_#{port}")
      end

      with_semian_configuration(semian_configuration_proc) do
        Net::HTTP.start(toxiproxy_upstream_host, http_toxiproxy_port) do |http|
          assert_equal semian_config["development"][http.semian_identifier],
                       http.raw_semian_options.dup.tap { |o| o.delete(:name) }
        end
      end
    end
  end

  def test_custom_raw_semian_options_can_only_assign_once
    semian_configuration_proc = proc do |host, port|
      DEFAULT_SEMIAN_OPTIONS.merge(name: "#{host}_#{port}")
    end
    with_semian_configuration(semian_configuration_proc) do
      assert_raises(Semian::NetHTTP::SemianConfigurationChangedError) do
        Semian::NetHTTP.semian_configuration = semian_configuration_proc
      end
    end
  end

  def test_custom_raw_semian_options_work_with_default_fallback
    with_server do
      semian_config = {}
      semian_config["development"] = {}
      semian_config["development"]["nethttp_default"] = DEFAULT_SEMIAN_OPTIONS
      sample_env = "development"

      semian_configuration_proc = proc do |host, port|
        semian_identifier = "nethttp_#{host}_#{port}"
        semian_identifier = "nethttp_default" unless semian_config[sample_env].key?(semian_identifier)
        semian_config[sample_env][semian_identifier].merge(name: "default")
      end
      Semian["nethttp_default"].reset if Semian["nethttp_default"]
      Semian.destroy("nethttp_default")
      with_semian_configuration(semian_configuration_proc) do
        Net::HTTP.start(SemianConfig['http_host'], SemianConfig['http_port_service_a']) do |http|
          expected_config = semian_config["development"]["nethttp_default"].dup
          assert_equal expected_config, http.raw_semian_options.dup.tap { |o| o.delete(:name) }
        end
      end
    end
  end

  def test_custom_raw_semian_options_can_disable_using_nil
    with_server do
      semian_configuration_proc = proc { nil }
      with_semian_configuration(semian_configuration_proc) do
        http = Net::HTTP.new(SemianConfig['toxiproxy_upstream_host'], SemianConfig['http_toxiproxy_port'])
        assert_equal true, http.disabled?
      end
    end
  end

  def test_use_custom_configuration_to_combine_endpoints_into_one_resource
    semian_config = {}
    semian_config["development"] = {}
    semian_config["development"]["nethttp_default"] = DEFAULT_SEMIAN_OPTIONS
    sample_env = "development"

    semian_configuration_proc = proc do |host, port|
      next nil if host == SemianConfig['toxiproxy_upstream_host'] && port == SemianConfig['toxiproxy_upstream_port'] # disable if toxiproxy
      semian_identifier = "nethttp_default"
      semian_config[sample_env][semian_identifier].merge(name: "default")
    end

    with_semian_configuration(semian_configuration_proc) do
      Semian["nethttp_default"].reset if Semian["nethttp_default"]
      Semian.destroy("nethttp_default")
      with_server do
        open_circuit!
      end
      with_server(ports: [SemianConfig['http_port_service_a'], SemianConfig['http_port_service_b']], reset_semian_state: false) do
        assert_raises Net::CircuitOpenError do
          Net::HTTP.get(URI("http://#{SemianConfig['toxiproxy_upstream_host']}:#{SemianConfig['http_toxiproxy_port']}/200"))
        end
      end
    end
  end

  def test_custom_raw_semian_options_can_disable_with_invalid_key
    with_server do
      toxiproxy_upstream_host = SemianConfig['toxiproxy_upstream_host']
      http_toxiproxy_port = SemianConfig['http_toxiproxy_port']

      semian_config = {}
      semian_config["development"] = {}
      semian_config["development"]["nethttp_#{toxiproxy_upstream_host}_#{http_toxiproxy_port}"] = DEFAULT_SEMIAN_OPTIONS
      sample_env = "development"

      semian_configuration_proc = proc do |host, port|
        semian_identifier = "nethttp_#{host}_#{port}"
        semian_config[sample_env][semian_identifier]
      end
      with_semian_configuration(semian_configuration_proc) do
        http = Net::HTTP.new(toxiproxy_upstream_host, http_toxiproxy_port)
        assert_equal false, http.disabled?

        http = Net::HTTP.new(toxiproxy_upstream_host, http_toxiproxy_port + 100)
        assert_equal true, http.disabled?
      end
    end
  end

  def test_adding_extra_errors_and_resetting_affects_exceptions_list
    orig_errors = Semian::NetHTTP.exceptions.dup
    Semian::NetHTTP.exceptions += [::OpenSSL::SSL::SSLError]
    assert_equal(orig_errors + [::OpenSSL::SSL::SSLError], Semian::NetHTTP.exceptions)
    Semian::NetHTTP.reset_exceptions
    assert_equal(Semian::NetHTTP::DEFAULT_ERRORS, Semian::NetHTTP.exceptions)
  ensure
    Semian::NetHTTP.exceptions = orig_errors
  end

  def test_adding_custom_errors_do_trip_circuit
    with_semian_configuration do
      with_custom_errors([::OpenSSL::SSL::SSLError]) do
        with_server do
          http = Net::HTTP.new(SemianConfig['toxiproxy_upstream_host'], SemianConfig['http_toxiproxy_port'])
          http.use_ssl = true
          http.raw_semian_options[:error_threshold].times do
            assert_raises ::OpenSSL::SSL::SSLError do
              http.get("/200")
            end
          end
          assert_raises Net::CircuitOpenError do
            http.get("/200")
          end
        end
      end
    end
  end

  def test_5xxs_trip_circuit_when_fatal_server_flag_enabled
    options = proc do |host, port|
      {
        tickets: 2,
        success_threshold: 1,
        error_threshold: 3,
        error_timeout: 10,
        open_circuit_server_errors: true,
        name: "#{host}_#{port}",
      }
    end

    with_semian_configuration(options) do
      with_server do
        http = Net::HTTP.new(SemianConfig['http_host'], SemianConfig['http_port_service_a'])
        http.raw_semian_options[:error_threshold].times do
          http.get("/500")
        end
        assert_raises Net::CircuitOpenError do
          http.get("/500")
        end
      end
    end
  end

  def test_5xxs_dont_raise_exceptions_unless_fatal_server_flag_enabled
    with_semian_configuration do
      with_server do
        http = Net::HTTP.new(SemianConfig['http_host'], SemianConfig['http_port_service_a'])
        http.raw_semian_options[:error_threshold].times do
          http.get("/500")
        end
        http.get("/500")
      end
    end
  end

  def test_multiple_different_endpoints_and_ports_are_tracked_differently
    with_semian_configuration do
      ports = [SemianConfig['http_port_service_a'], SemianConfig['http_port_service_b']]
      ports.each do |port|
        reset_semian_resource(port: port.to_i)
      end

      with_server(ports: ports, reset_semian_state: false) do |host, port|
        with_toxic(hostname: host, upstream_port: SemianConfig['http_port_service_a'], toxic_port: port + 1) do |name|
          Net::HTTP.get(URI("http://#{host}:#{port + 1}/"))
          open_circuit!(hostname: host, toxic_port: port + 1, toxic_name: name)
          assert_raises Net::CircuitOpenError do
            Net::HTTP.get(URI("http://#{host}:#{port + 1}/"))
          end
        end
      end
      with_server(ports: [SemianConfig['http_port_service_a']], reset_semian_state: false) do
        # different endpoint, should not raise errors even though localhost == 127.0.0.1
        Net::HTTP.get(URI("http://#{SemianConfig['toxiproxy_upstream_host']}:#{SemianConfig['http_toxiproxy_port']}/"))
      end
    end
  end

  def test_persistent_state_after_server_restart
    with_semian_configuration do
      with_server(ports: [SemianConfig['http_port_service_b']]) do |_, port|
        with_toxic(hostname: SemianConfig['http_host'], upstream_port: port, toxic_port: port + 1) do |name|
          open_circuit!(hostname: SemianConfig['toxiproxy_upstream_host'], toxic_port: port + 1, toxic_name: name)
        end
      end
      with_server(ports: [SemianConfig['http_port_service_b']], reset_semian_state: false) do |_, port|
        with_toxic(hostname: SemianConfig['http_host'], upstream_port: port, toxic_port: port + 1) do |_|
          assert_raises Net::CircuitOpenError do
            Net::HTTP.get(URI("http://#{SemianConfig['toxiproxy_upstream_host']}:#{port + 1}/200"))
          end
        end
      end
    end
  end

  private

  def half_open_cicuit!(backwards_time_travel = 10)
    Timecop.travel(Time.now - backwards_time_travel) do
      open_circuit!
    end
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

  def with_custom_errors(errors)
    orig_errors = Semian::NetHTTP.exceptions.dup
    Semian::NetHTTP.exceptions += errors
    yield
  ensure
    Semian::NetHTTP.exceptions = orig_errors
  end

  def get_subclasses(klass)
    ObjectSpace.each_object(klass.singleton_class).to_a - [klass]
  end

  def open_circuit!(hostname: nil, toxic_port: nil, toxic_name: "semian_test_net_http")
    hostname ||= SemianConfig['toxiproxy_upstream_host']
    toxic_port ||= SemianConfig['http_toxiproxy_port']

    Net::HTTP.start(hostname, toxic_port) do |http|
      http.read_timeout = 0.1
      uri = URI("http://#{hostname}:#{toxic_port}/200")
      http.raw_semian_options[:error_threshold].times do
        # Cause error error_threshold times so circuit opens
        Toxiproxy[toxic_name].downstream(:latency, latency: 500).apply do
          request = Net::HTTP::Get.new(uri)
          assert_raises Net::ReadTimeout do
            http.request(request)
          end
        end
      end
    end
  end

  def close_circuit!(hostname: SemianConfig['toxiproxy_upstream_host'], toxic_port: SemianConfig['http_toxiproxy_port'])
    http = Net::HTTP.new(hostname, toxic_port)
    Timecop.travel(http.raw_semian_options[:error_timeout])
    # Cause successes success_threshold times so circuit closes
    http.raw_semian_options[:success_threshold].times do
      response = http.get("/200")
      assert(200, response.code)
    end
  end

  def with_server(ports: [SemianConfig['http_port_service_a']], reset_semian_state: true)
    ports.each do |port|
      reset_semian_resource(port: port) if reset_semian_state
      @proxy = Toxiproxy[:semian_test_net_http]
      yield(BIND_ADDRESS, port.to_i)
    end
  end

  def reset_semian_resource(hostname: SemianConfig['toxiproxy_upstream_host'], port:)
    Semian["nethttp_#{hostname}_#{port}"].reset if Semian["nethttp_#{hostname}_#{port}"]
    Semian["nethttp_#{hostname}_#{port.to_i + 1}"].reset if Semian["nethttp_#{hostname}_#{port.to_i + 1}"]
    Semian.destroy("nethttp_#{hostname}_#{port}")
    Semian.destroy("nethttp_#{hostname}_#{port.to_i + 1}")
  end

  def with_toxic(hostname: SemianConfig['http_host'], upstream_port: SemianConfig['http_port_service_a'], toxic_port: upstream_port + 1)
    old_proxy = @proxy
    name = "semian_test_net_http_#{hostname}_#{upstream_port}<-#{toxic_port}"
    Toxiproxy.populate([
      {
        name: name,
        upstream: "#{hostname}:#{upstream_port}",
        listen: "#{SemianConfig['toxiproxy_upstream_host']}:#{toxic_port}",
      },
    ])
    @proxy = Toxiproxy[name]
    yield(name)
  rescue StandardError
  ensure
    @proxy = old_proxy
    begin
      Toxiproxy[name].destroy
    rescue StandardError
    end
  end
end
