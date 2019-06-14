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

    if ENV['CIRCUIT_IMPL'] != 'ruby'
      # Without locks, this only passes around 1 in every 5 runs
      def test_increment_race
        process_count = 255
        100.times do
          process_count.times do
            fork do
              value = @integer.increment(1)
              exit!(value)
            end
          end
          exit_codes = Process.waitall.map { |_, status| status.exitstatus }
          # No two processes should exit with the same exit code
          duplicate_values = exit_codes.group_by { |i| i }.select { |_, v| v.size > 1 }
          puts "Duplicate values: #{duplicate_values}" unless duplicate_values.empty?
          assert_equal(process_count, exit_codes.uniq.length)
        end
      end
    end
  end

  include IntegerTestCases
end
