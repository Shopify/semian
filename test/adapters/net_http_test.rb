# frozen_string_literal: true

require "test_helper"
require "semian/net_http"

class TestNetHTTP < Minitest::Test
  DEFAULT_SEMIAN_OPTIONS = {
    tickets: 3,
    success_threshold: 1,
    error_threshold: 3,
    error_timeout: 10,
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

  def test_semian_identifier
    with_server do
      with_semian_configuration do
        Net::HTTP.start(SemianConfig["toxiproxy_upstream_host"], SemianConfig["http_toxiproxy_port"]) do |http|
          assert_equal(
            "nethttp_#{SemianConfig["toxiproxy_upstream_host"]}_#{SemianConfig["http_toxiproxy_port"]}",
            http.semian_identifier,
          )
        end
      end
    end
  end

  def test_changes_timeout_when_half_open_and_configured
    http = Net::HTTP.new(SemianConfig["toxiproxy_upstream_host"], SemianConfig["http_toxiproxy_port"])
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
        Toxiproxy["semian_test_net_http"].downstream(:latency, latency: 2000).apply do
          http.get("/200")
        end

        half_open_cicuit!

        Toxiproxy["semian_test_net_http"].downstream(:latency, latency: 2000).apply do
          assert_raises(Net::ReadTimeout) do
            http.get("/200")
          end
        end
      end
    end

    assert_equal(expected_read_timeout, http.read_timeout)
    assert_equal(expected_open_timeout, http.open_timeout)
  end

  def test_trigger_open
    with_semian_configuration do
      with_server do
        open_circuit!

        uri = URI("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        exception = assert_raises(Net::CircuitOpenError) do
          Net::HTTP.get(uri)
        end

        assert_equal("Net::ReadTimeout", exception.cause.to_s)
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
        http_1 = Net::HTTP.new(SemianConfig["toxiproxy_upstream_host"], SemianConfig["http_toxiproxy_port"])
        http_1.semian_resource.acquire do
          http_2 = Net::HTTP.new(SemianConfig["toxiproxy_upstream_host"], SemianConfig["http_toxiproxy_port"])

          http_2.semian_resource.acquire do
            assert_raises(Net::ResourceBusyError) do
              Net::HTTP.get(URI("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/"))
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
        assert_raises(Net::CircuitOpenError) do
          Net::HTTP.get(URI("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200"))
        end
      end
    end
  end

  def test_instance_get_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!

        http = Net::HTTP.new(SemianConfig["toxiproxy_upstream_host"], SemianConfig["http_toxiproxy_port"])
        assert_raises(Net::CircuitOpenError) do
          http.get("/")
        end
      end
    end
  end

  def test_get_response_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!

        uri = URI("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        assert_raises(Net::CircuitOpenError) do
          Net::HTTP.get_response(uri)
        end
      end
    end
  end

  def test_post_form_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!

        uri = URI("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        assert_raises(Net::CircuitOpenError) do
          Net::HTTP.post_form(uri, "q" => "ruby", "max" => "50")
        end
      end
    end
  end

  def test_http_start_method_is_protected
    with_semian_configuration do
      with_server do
        open_circuit!

        uri = URI("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        assert_raises(Net::CircuitOpenError) do
          Net::HTTP.start(uri.host, uri.port) {}
        end
        close_circuit!
      end
    end
  end

  def test_http_action_request_inside_start_methods_are_protected
    with_semian_configuration do
      with_server do
        uri = URI("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200")
        Net::HTTP.start(uri.host, uri.port) do |http|
          open_circuit!
          get_subclasses(Net::HTTPRequest).each do |action|
            request = action.new(uri)
            assert_raises(Net::CircuitOpenError, "#{action.name} did not raise a Net::CircuitOpenError") do
              http.request(request)
            end
          end
        end
      end
    end
  end

  def test_custom_raw_semian_options_work_with_lookup
    with_server do
      toxiproxy_upstream_host = SemianConfig["toxiproxy_upstream_host"]
      http_toxiproxy_port = SemianConfig["http_toxiproxy_port"]

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
          assert_equal(
            semian_config["development"][http.semian_identifier],
            http.raw_semian_options.dup.tap { |o| o.delete(:name) },
          )
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
      Semian["nethttp_default"]&.reset
      Semian.destroy("nethttp_default")
      with_semian_configuration(semian_configuration_proc) do
        Net::HTTP.start(SemianConfig["http_host"], SemianConfig["http_port_service_a"]) do |http|
          expected_config = semian_config["development"]["nethttp_default"].dup

          assert_equal(expected_config, http.raw_semian_options.dup.tap { |o| o.delete(:name) })
        end
      end
    end
  end

  def test_custom_raw_semian_options_can_disable_using_nil
    with_server do
      semian_configuration_proc = proc { nil }
      with_semian_configuration(semian_configuration_proc) do
        http = Net::HTTP.new(SemianConfig["toxiproxy_upstream_host"], SemianConfig["http_toxiproxy_port"])

        assert_predicate(http, :disabled?)
      end
    end
  end

  def test_disable_semian_should_be_false
    with_server do
      with_semian_configuration do
        http = Net::HTTP.new(SemianConfig["toxiproxy_upstream_host"], SemianConfig["http_toxiproxy_port"])

        refute_predicate(http, :disabled?)
      end
    end
  end

  def test_disable_semian_for_all_http_requests_with_flag
    with_server do
      with_semian_configuration do
        http = Net::HTTP.new(
          SemianConfig["toxiproxy_upstream_host"],
          SemianConfig["http_toxiproxy_port"],
          semian: false,
        )

        assert_predicate(http, :disabled?)
      end
    end
  end

  def test_default_and_explicit_true_policies_inherit_the_global_configuration
    calls = 0
    configuration = proc do |host, port|
      calls += 1
      DEFAULT_SEMIAN_OPTIONS.merge(name: "#{host}_#{port}")
    end

    with_semian_configuration(configuration) do
      default_http = Net::HTTP.new("example.com", 80)
      explicit_http = Net::HTTP.new("example.com", 81, semian: true)

      assert_equal("example.com_80", default_http.raw_semian_options[:name])
      assert_equal("example.com_81", explicit_http.raw_semian_options[:name])
      assert_equal(2, calls)
    end
  end

  def test_explicit_policies_replace_the_global_configuration
    global_configuration_called = false
    configuration = proc do |host, port|
      global_configuration_called = true
      DEFAULT_SEMIAN_OPTIONS.merge(name: "platform_#{host}_#{port}")
    end

    with_semian_configuration(configuration) do
      disabled_in_constructor = Net::HTTP.new("example.com", 80, semian: false)
      disabled_with_setter = Net::HTTP.new("example.com", 80)
      disabled_with_setter.semian_policy = false

      first = Net::HTTP.new("example.com", 80, semian: caller_semian_options("caller_one"))
      second = Net::HTTP.new("example.com", 80)
      second.semian_policy = caller_semian_options("caller_two")

      assert_predicate(disabled_in_constructor, :disabled?)
      assert_predicate(disabled_with_setter, :disabled?)
      assert_equal("nethttp_caller_one", first.semian_identifier)
      assert_equal("nethttp_caller_two", second.semian_identifier)
      refute_same(first.semian_resource, second.semian_resource)
      assert_nil(first.semian_resource.bulkhead)
      assert_nil(second.semian_resource.bulkhead)
      assert_includes(Semian.resources.keys, "nethttp_caller_one")
      assert_includes(Semian.resources.keys, "nethttp_caller_two")
      refute(global_configuration_called)
    end
  end

  def test_disabled_policy_has_an_unprotected_resource
    http = Net::HTTP.new("example.com", 80, semian: false)

    assert_equal("nethttp_example.com_80", http.semian_identifier)
    assert_instance_of(Semian::UnprotectedResource, http.semian_resource)
    assert_equal("nethttp_example.com_80", http.semian_resource.name)
  end

  def test_caller_owned_semian_policy_can_supply_a_bulkhead
    skip("SysV semaphores are only available on Linux") unless Semian.sysv_semaphores_supported?

    http = Net::HTTP.new("example.com", 80, semian: DEFAULT_SEMIAN_OPTIONS.merge(name: "caller", tickets: 2))

    assert_equal(2, http.semian_resource.tickets)
  end

  def test_caller_owned_semian_policy_requires_a_valid_name
    invalid_names = [nil, "", "line\nbreak", "a" * 256, Object.new]

    invalid_names.each do |name|
      error = assert_raises(ArgumentError) do
        Net::HTTP.new("example.com", 80, semian: DEFAULT_SEMIAN_OPTIONS.merge(name: name))
      end

      assert_equal("semian_policy :name must be a non-empty String or Symbol up to 255 bytes", error.message)
    end
  end

  def test_semian_policy_rejects_invalid_modes
    [nil, :disabled].each do |policy|
      error = assert_raises(ArgumentError) do
        Net::HTTP.new("example.com", 80, semian: policy)
      end

      assert_equal("semian_policy must be true, false, or a Hash", error.message)
    end
  end

  def test_caller_owned_semian_policy_cannot_be_dynamic
    error = assert_raises(ArgumentError) do
      Net::HTTP.new("example.com", 80, semian: caller_semian_options("caller").merge(dynamic: true))
    end

    assert_equal("semian_policy cannot be dynamic", error.message)
  end

  def test_subclasses_cannot_use_semian_before_constructor_policy_assignment
    http_class = Class.new(Net::HTTP) do
      def initialize(*)
        super
        raw_semian_options
      end
    end

    with_semian_configuration do
      assert_raises(Semian::NetHTTP::SemianPolicyChangedError) do
        http_class.new("example.com", 80, semian: false)
      end
    end
  end

  def test_semian_policy_can_only_be_assigned_once_before_use
    http = Net::HTTP.new("example.com", 80)
    options = caller_semian_options("caller")

    http.semian_policy = options
    http.semian_policy = options.dup

    assert_raises(Semian::NetHTTP::SemianPolicyChangedError) do
      http.semian_policy = false
    end

    explicitly_disabled_http = Net::HTTP.new("example.com", 80, semian: false)
    assert_raises(Semian::NetHTTP::SemianPolicyChangedError) do
      explicitly_disabled_http.semian_policy = true
    end
  end

  def test_semian_policy_cannot_change_after_raw_options_are_used
    http = Net::HTTP.new("example.com", 80)

    with_semian_configuration do
      http.raw_semian_options

      http.semian_policy = true
      assert_raises(Semian::NetHTTP::SemianPolicyChangedError) do
        http.semian_policy = false
      end
    end
  end

  def test_semian_policy_cannot_change_after_resource_acquisition
    options = caller_semian_options("caller")
    http = Net::HTTP.new("example.com", 80, semian: options)

    http.semian_resource
    http.semian_policy = options.dup

    assert_raises(Semian::NetHTTP::SemianPolicyChangedError) do
      http.semian_policy = caller_semian_options("other")
    end
  end

  def test_semian_policy_copies_and_freezes_caller_options
    name = +"caller"
    exceptions = [RuntimeError]
    metadata = { owner: +"caller" }
    options = caller_semian_options(name).merge(exceptions: exceptions, metadata: metadata)
    http = Net::HTTP.new("example.com", 80, semian: options)

    name.replace("changed")
    exceptions << IOError
    metadata[:owner].replace("changed")
    metadata[:new_key] = true
    options[:error_threshold] = 100

    assert_equal("caller", http.semian_policy[:name])
    assert_equal([RuntimeError], http.semian_policy[:exceptions])
    assert_equal({ owner: "caller" }, http.semian_policy[:metadata])
    assert_equal(DEFAULT_SEMIAN_OPTIONS[:error_threshold], http.semian_policy[:error_threshold])
    assert_predicate(http.semian_policy, :frozen?)
    assert_predicate(http.semian_policy[:name], :frozen?)
    assert_predicate(http.semian_policy[:exceptions], :frozen?)
    assert_predicate(http.semian_policy[:metadata], :frozen?)
    assert_predicate(http.semian_policy[:metadata][:owner], :frozen?)
    assert_predicate(http.raw_semian_options, :frozen?)
    assert_raises(FrozenError) { http.semian_policy[:name] = "changed" }
    assert_raises(FrozenError) { http.semian_policy[:name].replace("changed") }
    assert_raises(FrozenError) { http.semian_policy[:exceptions] << IOError }
    assert_raises(FrozenError) { http.semian_policy[:metadata][:owner].replace("changed") }
    assert_raises(FrozenError) { http.raw_semian_options[:name] = "changed" }
  end

  def test_semian_policy_assignment_is_synchronized_with_first_use
    configuration_started = Queue.new
    continue_configuration = Queue.new
    configuration = proc do |host, port|
      configuration_started << true
      continue_configuration.pop
      DEFAULT_SEMIAN_OPTIONS.merge(name: "#{host}_#{port}")
    end

    with_semian_configuration(configuration) do
      http = Net::HTTP.new("example.com", 80)
      lookup = Thread.new { http.raw_semian_options }
      configuration_started.pop
      assignment = Thread.new do
        http.semian_policy = false
      rescue => error
        error
      end

      assignment_was_blocked = assignment.join(0.01).nil?
      continue_configuration << true
      lookup.join

      assert(assignment_was_blocked)
      assert_instance_of(Semian::NetHTTP::SemianPolicyChangedError, assignment.value)
      assert(http.semian_policy)
      assert_equal("example.com_80", http.raw_semian_options[:name])
    end
  end

  def test_concurrent_first_policy_assignments_cannot_overwrite_each_other
    http = Net::HTTP.new("example.com", 80)
    ready = Queue.new
    start = Queue.new
    policies = [false, caller_semian_options("caller")]
    assignments = policies.map do |policy|
      Thread.new do
        ready << true
        start.pop
        http.semian_policy = policy
      rescue => error
        error
      end
    end
    policies.length.times { ready.pop }
    policies.length.times { start << true }
    results = assignments.map(&:value)

    assert_equal(1, results.count { |result| result.is_a?(Semian::NetHTTP::SemianPolicyChangedError) })
    assert_includes(policies, http.semian_policy)
  end

  def test_use_custom_configuration_to_combine_endpoints_into_one_resource
    semian_config = {}
    semian_config["development"] = {}
    semian_config["development"]["nethttp_default"] = DEFAULT_SEMIAN_OPTIONS
    sample_env = "development"

    semian_configuration_proc = proc do |host, port|
      if host == SemianConfig["toxiproxy_upstream_host"] &&
          port == SemianConfig["toxiproxy_upstream_port"] # disable if toxiproxy
        next nil
      end

      semian_identifier = "nethttp_default"
      semian_config[sample_env][semian_identifier].merge(name: "default")
    end

    with_semian_configuration(semian_configuration_proc) do
      Semian["nethttp_default"]&.reset
      Semian.destroy("nethttp_default")
      with_server do
        open_circuit!
      end

      with_server(
        ports: [SemianConfig["http_port_service_a"], SemianConfig["http_port_service_b"]],
        reset_semian_state: false,
      ) do
        assert_raises(Net::CircuitOpenError) do
          Net::HTTP.get(URI("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/200"))
        end
      end
    end
  end

  def test_custom_raw_semian_options_can_disable_with_invalid_key
    with_server do
      toxiproxy_upstream_host = SemianConfig["toxiproxy_upstream_host"]
      http_toxiproxy_port = SemianConfig["http_toxiproxy_port"]

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

        refute_predicate(http, :disabled?)

        http = Net::HTTP.new(toxiproxy_upstream_host, http_toxiproxy_port + 100)

        assert_predicate(http, :disabled?)
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
          http = Net::HTTP.new(SemianConfig["toxiproxy_upstream_host"], SemianConfig["http_toxiproxy_port"])
          http.use_ssl = true
          http.raw_semian_options[:error_threshold].times do
            assert_msg = "for HTTP request to #{SemianConfig["toxiproxy_upstream_host"]}:" \
              "#{SemianConfig["http_toxiproxy_port"]}"
            assert_raises(::OpenSSL::SSL::SSLError, assert_msg) do
              http.get("/200")
            end
          end
          assert_raises(Net::CircuitOpenError) do
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
        http = Net::HTTP.new(SemianConfig["http_host"], SemianConfig["http_port_service_a"])
        http.raw_semian_options[:error_threshold].times do
          http.get("/500")
        end
        assert_raises(Net::CircuitOpenError) do
          http.get("/500")
        end
      end
    end
  end

  def test_5xxs_emit_state_changes_with_scope_and_adapter
    options = proc do |host, port|
      {
        tickets: 2,
        success_threshold: 1,
        error_threshold: 1,
        error_timeout: 10,
        open_circuit_server_errors: true,
        name: "#{host}_#{port}",
      }
    end

    events = []
    subscriber = Semian.subscribe do |event, _resource, scope, adapter|
      events << { adapter: adapter, scope: scope } if event == :state_change
    end

    with_semian_configuration(options) do
      with_server do
        http = Net::HTTP.new(SemianConfig["http_host"], SemianConfig["http_port_service_a"])
        http.get("/500")
      end
    end

    assert_includes(events, { adapter: :http, scope: :query })
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_5xxs_dont_raise_exceptions_unless_fatal_server_flag_enabled
    skip if ENV["SKIP_FLAKY_TESTS"]
    with_semian_configuration do
      with_server do
        http = Net::HTTP.new(SemianConfig["http_host"], SemianConfig["http_port_service_a"])
        http.raw_semian_options[:error_threshold].times do
          http.get("/500")
        end
        http.get("/500")
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
          Net::HTTP.get(URI("http://#{host}:#{port + 1}/"))
          open_circuit!(hostname: host, toxic_port: port + 1, toxic_name: name)
          assert_raises(Net::CircuitOpenError) do
            Net::HTTP.get(URI("http://#{host}:#{port + 1}/"))
          end
        end
      end
      with_server(ports: [SemianConfig["http_port_service_a"]], reset_semian_state: false) do
        # different endpoint, should not raise errors even though localhost == 127.0.0.1
        Net::HTTP.get(URI("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}/"))
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
          assert_raises(Net::CircuitOpenError) do
            Net::HTTP.get(URI("http://#{SemianConfig["toxiproxy_upstream_host"]}:#{port + 1}/200"))
          end
        end
      end
    end
  end

  def test_semian_disabled_env
    ENV["SEMIAN_DISABLED"] = "1"
    with_server do
      with_semian_configuration do
        http = Net::HTTP.new("shopify.com", 80)

        assert_equal("nethttp_shopify.com_80", http.semian_identifier)
      end
    end
  ensure
    ENV.delete("SEMIAN_DISABLED")
  end

  def test_dynamic_config
    options = proc do |host, port|
      DEFAULT_SEMIAN_OPTIONS.merge(
        dynamic: true,
        name: "#{host}_#{port}_#{Thread.current[:sub_resource_name]}",
      )
    end
    host = SemianConfig["toxiproxy_upstream_host"]
    port = SemianConfig["http_toxiproxy_port"]
    http = Net::HTTP.new(host, port)
    Thread.current[:sub_resource_name] = "service_a"

    with_semian_configuration(options) do
      with_server do
        http.get("/200")

        Thread.current[:sub_resource_name] = "service_b"
        http.get("/200")

        assert_includes(Semian.resources.keys, "nethttp_#{host}_#{port}_service_a")
        assert_includes(Semian.resources.keys, "nethttp_#{host}_#{port}_service_b")
      end
    end
  end

  private

  def caller_semian_options(name)
    DEFAULT_SEMIAN_OPTIONS.merge(name: name, bulkhead: false).except(:tickets)
  end

  def half_open_cicuit!(backwards_time_travel = 10)
    time_travel(-backwards_time_travel) do
      open_circuit!
    end
  end

  def with_semian_configuration(options = DEFAULT_SEMIAN_CONFIGURATION)
    orig_semian_options = Semian::NetHTTP.semian_configuration
    Semian::NetHTTP.instance_variable_set(:@semian_configuration, nil)
    mutated_objects = {}
    Semian::NetHTTP.alias_method(:orig_semian_resource, :semian_resource)
    Semian::NetHTTP.alias_method(:orig_raw_semian_options, :raw_semian_options)

    Semian::NetHTTP.alias_method(:semian_resource, :semian_resource) # Silence redefinition warnings
    Semian::NetHTTP.define_method(:semian_resource) do
      mutated_objects[self] = [@semian_resource, @raw_semian_options] unless mutated_objects.key?(self)
      orig_semian_resource
    end

    Semian::NetHTTP.alias_method(:raw_semian_options, :raw_semian_options) # Silence redefinition warnings
    Semian::NetHTTP.define_method(:raw_semian_options) do
      mutated_objects[self] = [@semian_resource, @raw_semian_options] unless mutated_objects.key?(self)
      orig_raw_semian_options
    end

    Semian::NetHTTP.semian_configuration = options
    yield
  ensure
    Semian::NetHTTP.instance_variable_set(:@semian_configuration, nil)
    Semian::NetHTTP.semian_configuration = orig_semian_options

    Semian::NetHTTP.alias_method(:semian_resource, :semian_resource) # Silence redefinition warnings
    Semian::NetHTTP.alias_method(:semian_resource, :orig_semian_resource)

    Semian::NetHTTP.alias_method(:raw_semian_options, :raw_semian_options) # Silence redefinition warnings
    Semian::NetHTTP.alias_method(:raw_semian_options, :orig_raw_semian_options)

    Semian::NetHTTP.undef_method(:orig_semian_resource, :orig_raw_semian_options)
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
    hostname ||= SemianConfig["toxiproxy_upstream_host"]
    toxic_port ||= SemianConfig["http_toxiproxy_port"]

    Net::HTTP.start(hostname, toxic_port) do |http|
      http.read_timeout = 0.1
      uri = URI("http://#{hostname}:#{toxic_port}/200")
      http.raw_semian_options[:error_threshold].times do
        # Cause error error_threshold times so circuit opens
        Toxiproxy[toxic_name].downstream(:latency, latency: 500).apply do
          request = Net::HTTP::Get.new(uri)
          assert_raises(Net::ReadTimeout, "for HTTP request to #{uri}") do
            http.request(request)
          end
        end
      end
    end
  end

  def close_circuit!(hostname: SemianConfig["toxiproxy_upstream_host"], toxic_port: SemianConfig["http_toxiproxy_port"])
    http = Net::HTTP.new(hostname, toxic_port)
    time_travel(http.raw_semian_options[:error_timeout]) do
      # Cause successes success_threshold times so circuit closes
      http.raw_semian_options[:success_threshold].times do
        response = http.get("/200")

        assert_equal(200, response.code.to_i)
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
    Semian["nethttp_#{hostname}_#{port}"]&.reset
    Semian["nethttp_#{hostname}_#{port.to_i + 1}"]&.reset
    Semian.destroy("nethttp_#{hostname}_#{port}")
    Semian.destroy("nethttp_#{hostname}_#{port.to_i + 1}")
  end

  def with_toxic(
    hostname: SemianConfig["http_host"],
    upstream_port: SemianConfig["http_port_service_a"],
    toxic_port: upstream_port + 1
  )
    old_proxy = @proxy
    name = "semian_test_net_http_#{hostname}_#{upstream_port}<-#{toxic_port}"
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
