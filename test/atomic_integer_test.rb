require 'test_helper'

class TestAtomicInteger < MiniTest::Unit::TestCase
  class FakeSysVAtomicInteger < Semian::AtomicInteger
    class << self
      attr_accessor :resources
    end
    self.resources = {}
    attr_accessor :name
    def self.new(name, permissions)
      obj = resources[name] ||= super
      obj.name = name
      obj
    end

    def destroy
      self.class.resources.delete(@name)
      super
    end

    def shared?
      true
    end
  end

  def setup
    @successes = Semian::SysVAtomicInteger.new('TestAtomicInteger', 0660)
    @successes.value = 0
  end

  def test_operations
    test_proc = proc do |atomic_integer|
      atomic_integer.value = 0
      atomic_integer.increment_by(4)
      assert_equal(4, atomic_integer.value)
      atomic_integer.value = 10
      assert_equal(10, atomic_integer.value)
    end
    test_proc.call(@successes)
    teardown
    @successes = Semian::AtomicInteger.new('TestAtomicInteger', 0660)
    test_proc.call(@successes)
  end

  def test_memory_is_shared
    run_test_once_with_sysv_and_once_without_sysv_to_assert_correctness do |klass|
      next unless @successes.shared?
      successes_2 = klass.new('TestAtomicInteger', 0660)
      successes_2.value = 100
      assert_equal 100, @successes.value
      @successes.value = 200
      assert_equal 200, successes_2.value
      @successes.value = 0
      assert_equal 0, successes_2.value
    end
  end

  def test_memory_not_reset_when_at_least_one_worker_using_it
    run_test_once_with_sysv_and_once_without_sysv_to_assert_correctness do |klass|
      next unless @successes.shared?

      @successes.value = 109
      successes_2 = klass.new('TestAtomicInteger', 0660)
      assert_equal @successes.value, successes_2.value
      pid = fork do
        successes_3 = klass.new('TestAtomicInteger', 0660)
        assert_equal 109, successes_3.value
        sleep
      end
      sleep 1
      Process.kill("KILL", pid)
      Process.waitall
      fork do
        successes_3 = klass.new('TestAtomicInteger', 0660)
        assert_equal 109, successes_3.value
      end
      Process.waitall
    end
  end

  def test_execute_atomically_actually_is_atomic
    Timeout.timeout(1) do # assure dont hang
      @successes.value = 100
      assert_equal 100, @successes.value
    end
    pids = []
    5.times do
      pids << fork do
        successes_2 = Semian::SysVAtomicInteger.new('TestAtomicInteger', 0660)
        successes_2.execute_atomically do
          successes_2.value += 1
          sleep 1
        end
      end
    end
    sleep 1
    pids.each { |pid| Process.kill('KILL', pid) }
    assert @successes.value < 105

    Process.waitall
  end

  def teardown
    @successes.destroy
  end

  private

  def run_test_once_with_sysv_and_once_without_sysv_to_assert_correctness
    yield(Semian::SysVAtomicInteger)
    teardown
    # Use fake class backed by lookup table by name to make sure results are correct
    @successes = FakeSysVAtomicInteger.new('TestAtomicInteger', 0660)
    yield(FakeSysVAtomicInteger)
  end
end
