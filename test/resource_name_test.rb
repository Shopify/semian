# frozen_string_literal: true

require "minitest/autorun"
require "semian"
require "helpers/resource_helper"

class TestResourceName < Minitest::Test
  include ResourceHelper

  def setup
    destroy_all_semian_resources
    @namespace = Semian.namespace
    Semian.namespace = nil
  end

  def teardown
    destroy_all_semian_resources
    Semian.namespace = @namespace
  end

  def test_register_rejects_null_bytes
    invalid_names.each do |name|
      error = assert_raises(ArgumentError) { register(name) }

      assert_equal("name must not contain null bytes", error.message)
      assert_nil(Semian[name])
    end
  end

  def test_retrieve_or_register_rejects_null_bytes
    invalid_names.each do |name|
      assert_raises(ArgumentError) do
        Semian.retrieve_or_register(name, tickets: 2, circuit_breaker: false)
      end
      assert_nil(Semian[name])
    end
  end

  def test_rejection_is_independent_of_configuration_validation
    [nil, false, true].each do |force_config_validation|
      assert_raises(ArgumentError) { register("testing\0other", force_config_validation:) }
    end
  end

  def test_register_rejects_null_bytes_when_disabled
    ["SEMIAN_DISABLED", "SEMIAN_BULKHEAD_DISABLED", "SEMIAN_SEMAPHORES_DISABLED"].each do |variable|
      with_env(variable, "1") do
        invalid_names.each do |name|
          assert_raises(ArgumentError) { register(name) }
          assert_nil(Semian[name])
        end
      end
    end
  end

  def test_register_rejects_null_bytes_with_bulkheads_disabled_in_thread
    Semian.disable_bulkheads_for_thread(Thread.current) do
      assert_raises(ArgumentError) { register("testing\0other", bulkhead: true) }
    end
  end

  def test_resource_rejects_null_bytes
    invalid_names.each do |name|
      error = assert_raises(ArgumentError) { create_resource(name) }

      assert_equal("name must not contain null bytes", error.message)
    end
  end

  def test_resource_rejects_null_bytes_when_semaphores_disabled
    with_env("SEMIAN_SEMAPHORES_DISABLED", "1") do
      invalid_names.each do |name|
        assert_raises(ArgumentError) { create_resource(name) }
      end
    end
  end

  def test_resource_rejects_null_bytes_in_namespace
    invalid_names.each do |namespace|
      Semian.namespace = namespace
      error = assert_raises(ArgumentError) { create_resource(:testing) }

      assert_equal("namespace must not contain null bytes", error.message)
    end
  end

  def test_registration_rejects_null_bytes_in_namespace
    Semian.namespace = "namespace\0other"

    error = assert_raises(ArgumentError) { register(:testing, bulkhead: true) }

    assert_equal("namespace must not contain null bytes", error.message)
    assert_nil(Semian[:testing])
  end

  def test_native_initialization_rejects_null_bytes
    skip("requires native semaphores") unless Semian.semaphores_enabled?

    invalid_names.each do |name|
      error = assert_raises(ArgumentError) { initialize_native_resource(name) }

      assert_equal("name must not contain null bytes", error.message)
    end
  end

  def test_rejection_does_not_modify_existing_semaphore
    skip("requires native semaphores") unless Semian.semaphores_enabled?

    resource = create_resource("testing")
    state = [resource.semid, resource.key, resource.tickets, resource.count, resource.registered_workers]

    ["testing\0other", :"testing\0other"].each do |name|
      assert_raises(ArgumentError) { register(name, bulkhead: true, tickets: 10) }
      assert_raises(ArgumentError) { create_resource(name, tickets: 10) }
      assert_raises(ArgumentError) { initialize_native_resource(name, tickets: 10) }

      assert_equal(state, [resource.semid, resource.key, resource.tickets, resource.count, resource.registered_workers])
      assert_nil(Semian[name])
    end
  end

  def test_valid_names_are_preserved
    ["testing", :testing, "café", :café, "testing\\0other", "\xFF".b].each do |name|
      assert_equal(name, register(name).name)
      assert_equal(name, create_resource(name).name)
    end
  end

  def test_valid_names_keep_existing_semaphore_keys
    skip("requires native semaphores") unless Semian.semaphores_enabled?

    string_resource = create_resource("testing")
    symbol_resource = create_resource(:testing)

    assert_equal("0x874714f2", string_resource.key)
    assert_equal(string_resource.semid, symbol_resource.semid)
    assert_equal(string_resource.semid, initialize_native_resource("testing").semid)
    assert_equal(string_resource.semid, initialize_native_resource(:testing).semid)

    Semian.namespace = "namespace"
    namespaced_resource = create_resource(:testing)
    Semian.namespace = nil
    equivalent_resource = create_resource("namespacetesting")

    assert_equal(namespaced_resource.semid, equivalent_resource.semid)
    refute_equal(string_resource.key, namespaced_resource.key)
  end

  private

  def invalid_names
    names = ["\0", "\0testing", "test\0ing", "testing\0"]
    names + names.map(&:to_sym) + ["testing".encode(Encoding::UTF_16LE), "\xFF\0".b]
  end

  def register(name, **options)
    Semian.register(name, tickets: 2, bulkhead: false, success_threshold: 1, error_threshold: 1, error_timeout: 1, **options)
  end

  def create_resource(name, **options)
    resource = Semian::Resource.new(name, tickets: 2, **options)
    (@resources ||= []) << resource
    resource
  end

  def initialize_native_resource(name, tickets: 2)
    resource = Semian::Resource.allocate
    resource.initialize_semaphore(name, tickets, nil, 0600, 0)
    (@resources ||= []) << resource
    resource
  end

  def with_env(variable, value)
    previous_value = ENV[variable]
    ENV[variable] = value
    yield
  ensure
    ENV[variable] = previous_value
  end
end
