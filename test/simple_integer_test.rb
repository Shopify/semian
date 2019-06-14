require 'test_helper'

class TestSimpleInteger < Minitest::Test
  def setup
    @integer = ::Semian::ThreadSafe::Integer.new(:simple_integer)
  end

  def teardown
    @integer.destroy
  end

  module IntegerTestCases
    def test_access_value
      assert_equal(0, @integer.value)
      @integer.value = 99
      assert_equal(99, @integer.value)
      time_now = (Time.now).to_i
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

    def test_integer_race
      process_count = 255

      5.times do
        process_count.times do
          fork do
            # An attempt to run all the increments at approximately the same
            # time
            loop until Time.now.sec.modulo(2).zero?
            value = @integer.increment(1)
            exit!(value)
          end
        end

        finished_processes = Process.waitall

        exit_codes = finished_processes.map { |_, status| status.exitstatus }
        assert_equal((1..process_count).to_a, exit_codes)
        @integer.reset
      end
    end
  end

  include IntegerTestCases
end
