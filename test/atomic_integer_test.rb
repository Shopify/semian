require 'test_helper'

class TestAtomicInteger < MiniTest::Unit::TestCase
  def setup
    @successes = Semian::AtomicInteger.new("TestAtomicInteger",0660)
    @successes.value=0
  end

  def test_memory_is_shared
    return if !Semian::AtomicInteger.shared?
    successes_2 = Semian::AtomicInteger.new("TestAtomicInteger",0660)
    successes_2.value=100
    assert_equal 100, @successes.value
    @successes.value=200
    assert_equal 200, successes_2.value
    @successes.value = 0
    assert_equal 0, successes_2.value
  end

  def test_memory_not_reset_when_at_least_one_worker_using_it
    return if !Semian::AtomicInteger.shared?

    @successes.value = 109
    successes_2 = Semian::AtomicInteger.new("TestAtomicInteger",0660)
    pid = fork {
      successes_3 = Semian::AtomicInteger.new("TestAtomicInteger",0660)
      assert_equal 109,successes_3.value
      sleep
    }
    sleep 1
    Process.kill("KILL", pid)
    Process.waitall
    pid = fork {
      successes_3 = Semian::AtomicInteger.new("TestAtomicInteger",0660)
      assert_equal 109,successes_3.value
    }
    Process.waitall
  end

  def test_execute_atomically_actually_is_atomic
    Timeout::timeout(1) do #assure dont hang
      @successes.value=100
      assert_equal 100,@successes.value
    end
    pids = []
    5.times {
      pids << fork {
        successes_2 = Semian::AtomicInteger.new("TestAtomicInteger",0660)
        successes_2.execute_atomically {
          successes_2.value+=1
          sleep 1
        }
      }
    }
    sleep 1
    pids.each { |pid| Process.kill("KILL", pid) }
    assert (@successes.value < 105)

    Process.waitall
  end


  def teardown
    @successes.destroy
  end

end
