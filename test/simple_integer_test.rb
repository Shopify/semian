require 'test_helper'

class TestSimpleInteger < Minitest::Test
  def setup
    id = Time.now.strftime('%H:%M:%S.%N')
    @integer = ::Semian::ThreadSafe::Integer.new(id)
  end

  def teardown
    @integer.destroy unless @integer.nil?
  end

  module IntegerTestCases
    def test_access_value
      assert_equal(0, @integer.value)
      @integer.value = 99
      assert_equal(99, @integer.value)
      time_now = (Time.now).to_i % (2**15)
      @integer.value = time_now
      assert_equal(time_now, @integer.value)
      @integer.value = 6
      assert_equal(6, @integer.value)
      @integer.value = 6
      assert_equal(6, @integer.value)
    end

    def test_increment
      @integer.increment(4)
      assert_equal(4, @integer.value)
      @integer.increment
      assert_equal(5, @integer.value)
      @integer.increment(-2)
      assert_equal(3, @integer.value)
    end

    def test_reset_on_init
      assert_equal(0, @integer.value)
    end

    def test_reset
      @integer.increment(5)
      @integer.reset
      assert_equal(0, @integer.value)
    end

    def assert_equal_with_retry(expected)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time < 1.0
        return true if expected == yield
        sleep(0.1)
      end

      assert_equal(expected, yield)
    end

    # Without locks, this only passes around 1 in every 5 runs
    def test_increment_race
      process_count = 16
      10.times do
        pids = []

        id = Time.now.strftime('%H:%M:%S.%N')
        @integer = ::Semian::ThreadSafe::Integer.new(id)

        process_count.times do
          pids << fork do
            @integer.increment(1)
            sleep(60)
          end
        end

        if ENV['SEMIAN_CIRCUIT_BREAKER_IMPL'] == 'host'
          # Host-based circuits: Forked processes should increment the host integer.
          assert_equal_with_retry(process_count) { @integer.value }
        else
          # Worker-based circuits: Forked processes should increment the worker integer.
          assert_equal_with_retry(0) { @integer.value }
        end
      ensure
        pids.each { |pid| Process.kill('TERM', pid) }
      end
    end
  end

  include IntegerTestCases
end
