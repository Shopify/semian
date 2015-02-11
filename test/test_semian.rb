require 'test/unit'
require 'semian'
require 'tempfile'
require 'fileutils'

class TestSemian < Test::Unit::TestCase
  def setup
    Semian.destroy(:testing) rescue nil
  end

  def test_register_invalid_args
    assert_raises TypeError do
      Semian.register 123
    end
    assert_raises ArgumentError do
      Semian.register :testing, tickets: -1
    end
    assert_raises ArgumentError do
      Semian.register :testing, tickets: 1_000_000
    end
    assert_raises TypeError do
      Semian.register :testing, permissions: "test"
    end
  end

  def test_max_tickets
    assert Semian::MAX_TICKETS > 0
  end

  def test_register
    Semian.register :testing, tickets: 2
  end

  def test_register_with_no_tickets_raises
    assert_raises Semian::SyscallError do
      Semian.register :testing
    end
  end

  def test_acquire
    acquired = false
    Semian.register :testing, tickets: 1
    Semian[:testing].acquire { acquired = true }
    assert acquired
  end

  def test_acquire_return_val
    Semian.register :testing, tickets: 1
    val = Semian[:testing].acquire { 1234 }
    assert_equal 1234, val
  end

  def test_acquire_timeout
    Semian.register :testing, tickets: 1, timeout: 0.05

    acquired = false
    m = Monitor.new
    cond = m.new_cond

    t = Thread.start do
      m.synchronize do
        cond.wait_until { acquired }
        assert_raises Semian::TimeoutError do
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
    Semian.register :testing, tickets: 1, timeout: 0.01

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
    Semian.register :testing, tickets: 2, timeout: 0.5

    Semian[:testing].acquire do
      pid = fork do
        Semian.register :testing, timeout: 0.5
        Semian[:testing].acquire do
          assert_raises Semian::TimeoutError do
            Semian[:testing].acquire {  }
          end
        end
      end

      Process.wait
    end
  end

  def test_acquire_releases_on_kill
    begin
      Semian.register :testing, tickets: 1, timeout: 0.1
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
      assert_raises Semian::TimeoutError do
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
    Semian.register :testing, tickets: 2
    acquired = false

    Semian[:testing].acquire do
      acquired = true
      assert_equal 1, Semian[:testing].count
    end

    assert acquired
  end

  def test_sem_undo
    Semian.register :testing, tickets: 1

    # Ensure we don't hit ERANGE errors caused by lack of SEM_UNDO on semop* calls
    # by doing an acquire > SEMVMX (32767) times:
    #
    # See: http://lxr.free-electrons.com/source/ipc/sem.c?v=3.8#L419
    (1 << 16).times do # do an acquire 64k times
      Semian[:testing].acquire do
        1
      end
    end
  end

  def test_destroy
    Semian.register :testing, tickets: 1
    Semian[:testing].destroy
    assert_raises Semian::SyscallError do
      Semian[:testing].acquire { }
    end
  end

  def test_permissions
    Semian.register :testing, permissions: 0600, tickets: 1
    semid = Semian[:testing].semid
    `ipcs -s `.lines.each do |line|
      if /\s#{semid}\s/.match(line)
        assert_equal '600', line.split[3]
      end
    end

    Semian.register :testing, permissions: 0660, tickets: 1
    semid = Semian[:testing].semid
    `ipcs -s `.lines.each do |line|
      if /\s#{semid}\s/.match(line)
        assert_equal '660', line.split[3]
      end
    end
  end

  def test_resize_tickets_increase
    Semian.register :testing, tickets: 1

    acquired = false
    m = Monitor.new
    cond = m.new_cond

    t = Thread.start do
      m.synchronize do
        cond.wait_until { acquired }

        Semian.register :testing, tickets: 5
        assert_equal 4, Semian[:testing].count
      end
    end

    assert_equal 1, Semian[:testing].count

    Semian[:testing].acquire do
      acquired = true
      m.synchronize { cond.signal }
      sleep 0.2
    end

    t.join

    assert_equal 5, Semian[:testing].count
  end

  def test_resize_tickets_decrease
    Semian.register :testing, tickets: 5

    acquired = false
    m = Monitor.new
    cond = m.new_cond

    t = Thread.start do
      m.synchronize do
        cond.wait_until { acquired }

        Semian.register :testing, tickets: 1
        assert_equal 0, Semian[:testing].count
      end
    end

    assert_equal 5, Semian[:testing].count

    Semian[:testing].acquire do
      acquired = true
      m.synchronize { cond.signal }
      sleep 0.2
    end

    t.join

    assert_equal 1, Semian[:testing].count
  end

  def test_multiple_register_with_fork
    f = Tempfile.new('semian_test')

    begin
      f.flock(File::LOCK_EX)

      children = []
      5.times do
        children << fork do
          acquired = false

          f.flock(File::LOCK_SH)
          Semian.register(:testing, tickets: 5).acquire do |resource|
            assert resource.count < 5
            acquired = true
          end
          assert acquired
        end
      end
      children.compact!

      f.flock(File::LOCK_UN)

      while children.any? do
        children.delete(Process.wait)
      end

      assert_equal 5, Semian.register(:testing).count
    ensure
      f.close!
    end
  end

end
