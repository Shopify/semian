# frozen_string_literal: true

require "test_helper"
require "helpers/ractor_helper"

class TestRactor < Minitest::Test
  include RactorHelper

  RECORD_EVENT = Ractor.make_shareable(proc { |event, *| Ractor.store_if_absent(:events) { [] } << event })

  class RecordingLogger
    def info(message)
      Ractor.store_if_absent(:log) { [] } << message
    end
  end

  class Adapter
    include Semian::Adapter

    def semian_identifier
      :adapter
    end

    def raw_semian_options
      { bulkhead: false, error_threshold: 1, error_timeout: 10, success_threshold: 1 }
    end

    def resource_exceptions
      []
    end
  end

  def setup
    skip("Semian supports non-main Ractors from Ruby 3.4") unless Ractor.respond_to?(:main?)
  end

  def teardown
    destroy_all_semian_resources
  end

  def test_notifies_the_main_ractors_shareable_subscribers
    main_ractor_events = []
    Semian.subscribe(:shareable, &RECORD_EVENT)
    Semian.subscribe(:unsubscribed, &RECORD_EVENT)
    Semian.unsubscribe(:unsubscribed)
    Semian.subscribe(:unshareable) { |event, *| main_ractor_events << event }

    ractor = Ractor.new do
      Semian.notify(:event, nil, nil, nil)
      Ractor[:events]
    end

    assert_equal([:event], ractor_value(ractor))
    assert_empty(main_ractor_events)
  ensure
    Semian.unsubscribe(:shareable)
    Semian.unsubscribe(:unshareable)
  end

  def test_subscribes_in_a_non_main_ractor
    ractor = Ractor.new do
      events = []
      Semian.subscribe(:local) { |event, *| events << event }
      Semian.notify(:event, nil, nil, nil)
      subscribers = Semian.subscribers.keys
      Semian.unsubscribe(:local)
      Semian.notify(:event_after_unsubscribing, nil, nil, nil)
      [events, subscribers, Semian.subscribers.keys]
    end

    assert_equal([[:event], [:local], []], ractor_value(ractor))
    refute_includes(Semian.subscribers.keys, :local)
  end

  def test_logs_to_its_own_stderr_by_default
    ractor = Ractor.new do
      $stderr = StringIO.new
      Semian.logger.info("from a non-main Ractor")
      [$stderr.string.include?("from a non-main Ractor"), Semian.logger.equal?(Semian.logger)]
    end

    assert_equal([true, true], ractor_value(ractor))
  end

  def test_logs_to_the_main_ractors_logger_once_its_shareable
    logger = Semian.logger
    Semian.logger = RecordingLogger.new
    Ractor.make_shareable(Semian.logger)

    ractor = Ractor.new do
      Semian.logger.info("from a non-main Ractor")
      Ractor[:log]
    end

    assert_equal(["from a non-main Ractor"], ractor_value(ractor))
  ensure
    Semian.logger = logger
  end

  def test_sets_the_logger_in_a_non_main_ractor
    logger = Semian.logger
    ractor = Ractor.new do
      log = StringIO.new
      Semian.logger = Logger.new(log)
      Semian.logger.info("from a non-main Ractor")
      log.string.include?("from a non-main Ractor")
    end

    assert(ractor_value(ractor))
    assert_same(logger, Semian.logger)
  end

  def test_registers_resources_in_each_ractor
    Semian.register(:main, bulkhead: false, error_threshold: 1, error_timeout: 10, success_threshold: 1)

    ractor = Ractor.new do
      Semian.logger = Logger.new(nil)
      resource = Semian.register(
        :ractor,
        bulkhead: false,
        error_threshold: 2,
        error_timeout: 10,
        success_threshold: 1,
        exceptions: [IOError],
      )
      2.times do
        resource.acquire { raise IOError }
      rescue IOError
        nil
      end
      error = begin
        resource.acquire { :not_called }
      rescue Semian::OpenCircuitError => e
        e.class
      end
      registered = [Semian[:ractor].equal?(resource), Semian[:main]]
      Semian.reset!
      [error, registered, Semian.resources.size]
    end

    assert_equal([Semian::OpenCircuitError, [true, nil], 0], ractor_value(ractor))
    assert_nil(Semian[:ractor])
    refute_nil(Semian[:main])
  end

  def test_unregisters_an_adapters_resource_in_a_non_main_ractor
    ractor = Ractor.new do
      adapter = Adapter.new
      resource = adapter.semian_resource
      registered = Semian[:adapter].equal?(resource)
      Semian.unregister(:adapter)
      [registered, adapter.instance_variable_get(:@semian_resource), Semian[:adapter]]
    end

    assert_equal([true, nil, nil], ractor_value(ractor))
  end

  def test_reads_the_configuration_in_a_non_main_ractor
    namespace = Semian.namespace
    Semian.namespace = +"namespace_"

    ractor = Ractor.new { [Semian.namespace, Semian.thread_safe?, Semian.maximum_lru_size] }

    assert_equal(["namespace_", Semian.thread_safe?, Semian.maximum_lru_size], ractor_value(ractor))
  ensure
    Semian.namespace = namespace
  end

  def test_warns_once_in_each_ractor_that_semaphores_are_disabled
    skip("Semaphores are enabled") if Semian.semaphores_enabled?

    Semian.issue_disabled_semaphores_warning
    ractor = Ractor.new do
      $stderr = StringIO.new
      2.times { Semian.issue_disabled_semaphores_warning }
      $stderr.string.lines.size
    end

    assert_equal(1, ractor_value(ractor))
  end

  def test_shares_bulkheads_with_non_main_ractors
    skip("Semaphores are disabled") unless Semian.semaphores_enabled?

    resource = Semian.register(:ractor_test_bulkhead, tickets: 1, timeout: 0, circuit_breaker: false)
    result = resource.acquire do
      ractor = Ractor.new do
        bulkhead = Semian.register(:ractor_test_bulkhead, tickets: 1, timeout: 0, circuit_breaker: false)
        bulkhead.acquire { :not_called }
      rescue Semian::TimeoutError => error
        [error.class, bulkhead.registered_workers]
      end
      ractor_value(ractor)
    end

    assert_equal([Semian::TimeoutError, 2], result)
  end
end
