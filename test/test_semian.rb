require 'test/unit'
require 'semian'
require 'tempfile'
require 'fileutils'

class TestSemian < Test::Unit::TestCase
  def setup
    Semian[:testing].destroy rescue RuntimeError
  end

  def test_register_invalid_args
    assert_raises TypeError do
      Semian.register 'foo', 0, 0
    end
    assert_raises ArgumentError do
      Semian.register :testing, -1, 0
    end
  end

  def test_register
    Semian.register :testing, 2, 1
  end

  def test_acquire
    acquired = false
    Semian.register :testing, 1, 1
    Semian[:testing].acquire(timeout: 1) { acquired = true }
    assert acquired
  end

  def test_acquire_return_val
    Semian.register :testing, 1, 1
    val = Semian[:testing].acquire { 1234 }
    assert_equal 1234, val
  end

  def test_acquire_timeout
    Semian.register :testing, 1, 0.05

    acquired = false
    m = Monitor.new
    cond = m.new_cond

    t = Thread.start do
      m.synchronize do
        cond.wait_until { acquired }
        assert_raises Semian::Timeout do
          Semian[:testing].acquire { refute true }
        end
      end
    end

    Semian[:testing].acquire do
      acquired = true
      m.synchronize { cond.signal }
      sleep 0.2
    end

    t.join

    assert acquired
  end

  def test_acquire_timeout_override
    Semian.register :testing, 1, 0.01

    acquired = false
    thread_acquired = false
    m = Monitor.new
    cond = m.new_cond

    t = Thread.start do
      m.synchronize do
        cond.wait_until { acquired }
        Semian[:testing].acquire(timeout: 1) { thread_acquired = true }
      end
    end

    Semian[:testing].acquire do
      acquired = true
      m.synchronize { cond.signal }
      sleep 0.2
    end

    t.join

    assert acquired
    assert thread_acquired
  end

  def test_acquire_with_fork
    Semian.register :testing, 2, 0.5

    Semian[:testing].acquire do
      pid = fork do
        Semian.register :testing, 0, 0.5 # 0 to not reset the semaphore count
        Semian[:testing].acquire do
          assert_raises Semian::Timeout do
            Semian[:testing].acquire {  }
          end
        end
      end

      Process.wait
    end
  end

  def test_acquire_releases_on_kill
    begin
      Semian.register :testing, 1, 0.1
      acquired = false

      # Ghetto process synchronization
      file = Tempfile.new('semian')
      path = file.path
      file.close!

      pid = fork do
        Semian[:testing].acquire do
          FileUtils.touch(path)
          sleep 1000
        end
      end

      sleep 0.1 until File.exists?(path)
      assert_raises Semian::Timeout do
        Semian[:testing].acquire {}
      end

      Process.kill("KILL", pid)
      Semian[:testing].acquire { acquired = true }
      assert acquired

      Process.wait
    ensure
      FileUtils.rm_f(path) if path
    end
  end

  def test_count
    Semian.register :testing, 2, 1
    acquired = false

    Semian[:testing].acquire do
      acquired = true
      assert_equal 1, Semian[:testing].count
    end

    assert acquired
  end

  def test_destroy
    Semian.register :testing, 1, 1
    Semian[:testing].destroy
    assert_raises RuntimeError do
      Semian[:testing].acquire { }
    end
  end

end
