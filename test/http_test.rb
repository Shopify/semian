# frozen_string_literal: true

require "test_helper"
require "semian/http"

class TestHTTP < Minitest::Test
  ERROR_TIMEOUT = 10
  ERROR_THRESHOLD = 3
  SUCCESS_THRESHOLD = 1

  DEFAULT_SEMIAN_OPTIONS = {
    tickets: 3,
    success_threshold: SUCCESS_THRESHOLD,
    error_threshold: ERROR_THRESHOLD,
    error_timeout: ERROR_TIMEOUT,
  }.freeze
  DEFAULT_SEMIAN_CONFIGURATION = proc do |host, port|
    if host == SemianConfig["toxiproxy_upstream_host"] &&
        port == SemianConfig["toxiproxy_upstream_port"] # disable if toxiproxy
      next nil
    end

    DEFAULT_SEMIAN_OPTIONS.merge(name: "#{host}_#{port}")
  end

  def setup
    destroy_all_semian_resources
  end

  def teardown
    Thread.current[:sub_resource_name] = nil
  end

  def test_trigger_open
    with_semian_configuration do
      with_server do
        open_circuit!

        url = "http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200"
        exception = assert_raises(HTTP::CircuitOpenError) do
          HTTP.get(url)
        end

        assert_equal(HTTP::TimeoutError, exception.cause.class)
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

  def test_get_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!
        assert_raises(HTTP::CircuitOpenError) do
          HTTP.get("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        end
      end
    end
  end

  def test_head_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!
        assert_raises(HTTP::CircuitOpenError) do
          HTTP.head("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        end
      end
    end
  end

  def test_post_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!
        assert_raises(HTTP::CircuitOpenError) do
          HTTP.post("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        end
      end
    end
  end

  def test_put_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!
        assert_raises(HTTP::CircuitOpenError) do
          HTTP.put("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        end
      end
    end
  end

  def test_patch_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!
        assert_raises(HTTP::CircuitOpenError) do
          HTTP.patch("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        end
      end
    end
  end

  def test_delete_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!
        assert_raises(HTTP::CircuitOpenError) do
          HTTP.delete("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        end
      end
    end
  end

  def test_custom_raw_semian_options_can_only_assign_once
    semian_configuration_proc = proc do |host, port|
      DEFAULT_SEMIAN_OPTIONS.merge(name: "#{host}_#{port}")
    end

    with_semian_configuration(semian_configuration_proc) do
      assert_raises(Semian::HTTP::SemianConfigurationChangedError) do
        Semian::HTTP.semian_configuration = semian_configuration_proc
      end
    end
  end

  def test_use_custom_configuration_to_combine_endpoints_into_one_resource
    semian_config = {}
    semian_config["development"] = {}
    semian_config["development"]["http_gem_default"] = DEFAULT_SEMIAN_OPTIONS
    sample_env = "development"

    semian_configuration_proc = proc do |host, port|
      if host == SemianConfig["toxiproxy_upstream_host"] &&
          port == SemianConfig["toxiproxy_upstream_port"] # disable if toxiproxy
        next nil
      end

      semian_identifier = "http_gem_default"
      semian_config[sample_env][semian_identifier].merge(name: "default")
    end

    with_semian_configuration(semian_configuration_proc) do
      Semian["http_gem_default"]&.reset
      Semian.destroy("http_gem_default")
      with_server do
        open_circuit!
      end

      with_server(
        ports: [SemianConfig["http_port_service_a"], SemianConfig["http_port_service_b"]],
        reset_semian_state: false,
      ) do
        assert_raises(HTTP::CircuitOpenError) do
          HTTP.get("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        end
      end
    end
  end

  def test_adding_extra_errors_and_resetting_affects_exceptions_list
    orig_errors = Semian::HTTP.exceptions.dup
    Semian::HTTP.exceptions += [::OpenSSL::SSL::SSLError]

    assert_equal(orig_errors + [::OpenSSL::SSL::SSLError], Semian::HTTP.exceptions)
    Semian::HTTP.reset_exceptions

    assert_equal(Semian::HTTP::DEFAULT_ERRORS, Semian::HTTP.exceptions)
  ensure
    Semian::HTTP.exceptions = orig_errors
  end

  def test_adding_custom_errors_do_trip_circuit
    with_semian_configuration do
      with_custom_errors([::OpenSSL::SSL::SSLError]) do
        with_server do
          url = "https://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200"

          ERROR_THRESHOLD.times do
            assert_msg = "for HTTP request to #{SemianConfig["toxiproxy_upstream_host"]}:" \
              "#{SemianConfig["http_toxiproxy_port"]}"
            assert_raises(::OpenSSL::SSL::SSLError, assert_msg) do
              HTTP.get(url)
            end
          end

          assert_raises(HTTP::CircuitOpenError) do
            HTTP.get(url)
          end
        end
      end
    end
  end

  def test_5xxs_trip_circuit_when_fatal_server_flag_enabled
    options = proc do |host, port|
      {
        tickets: 2,
        success_threshold: SUCCESS_THRESHOLD,
        error_threshold: ERROR_THRESHOLD,
        error_timeout: ERROR_TIMEOUT,
        open_circuit_server_errors: true,
        name: "#{host}_#{port}",
      }
    end

    with_semian_configuration(options) do
      with_server do
        url = "http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/500"

        ERROR_THRESHOLD.times do
          HTTP.get(url)
        end

        assert_raises(HTTP::CircuitOpenError) do
          HTTP.get(url)
        end
      end
    end
  end

  def test_5xxs_dont_raise_exceptions_unless_fatal_server_flag_enabled
    skip if ENV["SKIP_FLAKY_TESTS"]
    with_semian_configuration do
      with_server do
        url = "http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/500"

        ERROR_THRESHOLD.times do
          HTTP.get(url)
        end

        HTTP.get(url)
      end
    end
  end

  def test_multiple_different_endpoints_and_ports_are_tracked_differently
    with_semian_configuration do
      ports = [SemianConfig["http_port_service_a"], SemianConfig["http_port_service_b"]]
      ports.each do |port|
        reset_semian_resource(port: port.to_i)
      end

      with_server(ports: ports, reset_semian_state: false) do |host, port|
        with_toxic(hostname: host, upstream_port: SemianConfig["http_port_service_a"], toxic_port: port + 1) do |name|
          HTTP.get("http://#{host}:#{port + 1}/")
          open_circuit!(hostname: host, toxic_port: port + 1, toxic_name: name)
          assert_raises(HTTP::CircuitOpenError) do
            HTTP.get("http://#{host}:#{port + 1}/")
          end
        end
      end
      with_server(ports: [SemianConfig["http_port_service_a"]], reset_semian_state: false) do
        # different endpoint, should not raise errors even though localhost == 127.0.0.1
        HTTP.get("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/")
      end
    end
  end

  def test_persistent_state_after_server_restart
    with_semian_configuration do
      with_server(ports: [SemianConfig["http_port_service_b"]]) do |_, port|
        with_toxic(hostname: SemianConfig["http_host"], upstream_port: port, toxic_port: port + 1) do |name|
          open_circuit!(hostname: SemianConfig["toxiproxy_upstream_host"], toxic_port: port + 1, toxic_name: name)
        end
      end
      with_server(ports: [SemianConfig["http_port_service_b"]], reset_semian_state: false) do |_, port|
        with_toxic(hostname: SemianConfig["http_host"], upstream_port: port, toxic_port: port + 1) do |_|
          assert_raises(HTTP::CircuitOpenError) do
            HTTP.get("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{port + 1}/200")
          end
        end
      end
    end
  end

  private

  def with_semian_configuration(options = DEFAULT_SEMIAN_CONFIGURATION)
    orig_semian_options = Semian::HTTP.semian_configuration
    Semian::HTTP.instance_variable_set(:@semian_configuration, nil)
    mutated_objects = {}
    Semian::HTTP.send(:alias_method, :orig_semian_resource, :semian_resource)
    Semian::HTTP.send(:alias_method, :orig_raw_semian_options, :raw_semian_options)
    Semian::HTTP.send(:define_method, :semian_resource) do
      mutated_objects[self] = [@semian_resource, @raw_semian_options] unless mutated_objects.key?(self)
      orig_semian_resource
    end
    Semian::HTTP.send(:define_method, :raw_semian_options) do
      mutated_objects[self] = [@semian_resource, @raw_semian_options] unless mutated_objects.key?(self)
      orig_raw_semian_options
    end

    Semian::HTTP.semian_configuration = options
    yield
  ensure
    Semian::HTTP.instance_variable_set(:@semian_configuration, nil)
    Semian::HTTP.semian_configuration = orig_semian_options
    Semian::HTTP.send(:alias_method, :semian_resource, :orig_semian_resource)
    Semian::HTTP.send(:alias_method, :raw_semian_options, :orig_raw_semian_options)
    Semian::HTTP.send(:undef_method, :orig_semian_resource, :orig_raw_semian_options)
    mutated_objects.each do |instance, (res, opt)| # Sadly, only way to fully restore cached properties
      instance.instance_variable_set(:@semian_resource, res)
      instance.instance_variable_set(:@raw_semian_options, opt)
    end
  end

  def with_custom_errors(errors)
    orig_errors = Semian::HTTP.exceptions.dup
    Semian::HTTP.exceptions += errors
    yield
  ensure
    Semian::HTTP.exceptions = orig_errors
  end

  def open_circuit!(hostname: nil, toxic_port: nil, toxic_name: "semian_test_net_http")
    hostname ||= SemianConfig["toxiproxy_upstream_host"]
    toxic_port ||= SemianConfig["http_toxiproxy_port"]
    url = "http://#{hostname}:#{toxic_port}/200"
    ERROR_THRESHOLD.times do
      # Cause error error_threshold times so circuit opens
      Toxiproxy[toxic_name].downstream(:latency, latency: 500).apply do
        assert_raises(HTTP::TimeoutError, "for HTTP request to #{url}") do
          HTTP.timeout(read: 0.1).get(url)
        end
      end
    end
  end

  def close_circuit!(hostname: SemianConfig["toxiproxy_upstream_host"], toxic_port: SemianConfig["http_toxiproxy_port"])
    time_travel(ERROR_TIMEOUT) do
      # Cause successes success_threshold times so circuit closes
      SUCCESS_THRESHOLD.times do
        response = HTTP.get("http://#{hostname}:#{toxic_port}/200")

        assert_equal(200, response.status.to_i)
      end
    end
  end

  def with_server(ports: [SemianConfig["http_port_service_a"]], reset_semian_state: true)
    ports.each do |port|
      reset_semian_resource(port: port) if reset_semian_state
      @proxy = Toxiproxy[:semian_test_net_http]
      yield(BIND_ADDRESS, port.to_i)
    end
  end

  def reset_semian_resource(hostname: SemianConfig["toxiproxy_upstream_host"], port:)
    Semian["http_gem_#{hostname}_#{port}"]&.reset
    Semian["http_gem_#{hostname}_#{port.to_i + 1}"]&.reset
    Semian.destroy("http_gem_#{hostname}_#{port}")
    Semian.destroy("http_gem_#{hostname}_#{port.to_i + 1}")
  end

  def with_toxic(
    hostname: SemianConfig["http_host"],
    upstream_port: SemianConfig["http_port_service_a"],
    toxic_port: upstream_port + 1
  )
    old_proxy = @proxy
    name = "semian_test_http_gem_#{hostname}_#{upstream_port}<-#{toxic_port}"
    Toxiproxy.populate([
      {
        name: name,
        upstream: "#{hostname}:#{upstream_port}",
        listen: "#{SemianConfig["toxiproxy_upstream_host"]}:#{toxic_port}",
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
