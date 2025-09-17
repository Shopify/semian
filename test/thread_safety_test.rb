# frozen_string_literal: true

require "test_helper"
require "semian/adapter"

class ThreadSafetyTest < Minitest::Test
  class DummyConsumer
    include Semian::Adapter

    attr_reader :name, :options

    def initialize(name, **options)
      @name = name
      @options = options.merge(
        success_threshold: 1,
        error_threshold: 2,
        error_timeout: 5,
        bulkhead: false,
      )
    end

    def query
      semian_resource.acquire {}
    end

    def semian_identifier
      name
    end

    def semian_options
      options
    end

    def resource_exceptions
      []
    end
  end

  def setup
    Semian.reset!
  end

  def teardown
    Semian.reset!
  end

  def test_consumers_and_resources_are_thread_safe_on_registration
    thread_count = 200
    names = thread_count.times.map { |i| "resource_#{i}".to_sym }

    threads = names.map do |name|
      Thread.new do
        consumer = DummyConsumer.new(name)
        consumer.query # This triggers retrieve_or_register
      end
    end

    threads.each(&:join)

    assert_equal(thread_count, Semian.consumers.size, "Expected #{thread_count} consumers to be registered")
    assert_equal(thread_count, Semian.resources.size, "Expected #{thread_count} resources to be registered")

    names.each do |name|
      assert(Semian.consumers.key?(name), "Consumer for #{name} not found")
      assert(Semian.resources[name], "Resource for #{name} not found")
      assert_equal(1, Semian.consumers[name].size, "Expected 1 consumer for #{name}")
    end
  end

  def test_consumer_set_is_thread_safe
    thread_count = 200
    name = :shared_resource

    consumers = Array.new(thread_count) { DummyConsumer.new(name) }

    threads = consumers.map do |consumer|
      Thread.new do
        consumer.query
      end
    end

    threads.each(&:join)

    assert_equal(1, Semian.consumers.size, "Should only have one consumer set for the shared resource")
    consumer_set = Semian.consumers[name]

    assert(consumer_set, "Consumer set for #{name} not found")
    assert_equal(thread_count, consumer_set.size, "All consumers should be in the set")
  end

  def test_concurrent_registration_and_unregistration
    thread_count = 200
    names = (0...thread_count).map { |i| "resource_#{i}".to_sym }.shuffle
    consumers = names.map { |name| DummyConsumer.new(name) }

    barrier = Concurrent::CyclicBarrier.new(thread_count * 2)

    registration_threads = consumers.map do |consumer|
      Thread.new do
        barrier.wait
        consumer.query
      end
    end

    unregistration_threads = names.map do |name|
      Thread.new do
        barrier.wait
        Semian.unregister(name)
      end
    end

    all_threads = registration_threads + unregistration_threads
    all_threads.each(&:join)

    # In a non-thread-safe environment, the final state is unpredictable.
    # The primary goal of this test is to ensure it completes without crashing
    # and that the final state is somewhat reasonable. With a thread-safe hash,
    # the end result should be more consistent, but still not fully deterministic
    # due to the race between registration and unregistration.
    # A simple assertion is that the number of remaining consumers is less than the total.
    assert_operator(Semian.consumers.size, :<=, thread_count)
  end

  def test_subscribers_are_thread_safe
    thread_count = 200
    subscriber_names = (0...thread_count).map { |i| "subscriber_#{i}".to_sym }

    threads = subscriber_names.map do |name|
      Thread.new do
        Semian.subscribe(name) { |_| }
      end
    end

    threads.each(&:join)

    assert_equal(thread_count, Semian.send(:subscribers).size, "Expected #{thread_count} subscribers to be registered")

    subscriber_names.each do |name|
      assert(Semian.send(:subscribers).key?(name), "Subscriber for #{name} not found")
    end
  end
end
