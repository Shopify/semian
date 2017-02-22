require 'test_helper'

class TestResource < Minitest::Test
  def setup
    Semian.destroy(:testing)
  rescue
    nil
  end

  def teardown
    destroy_resources
  end

  def test_initialize_invalid_args
    assert_raises TypeError do
      create_resource 123, tickets: 2
    end
    assert_raises ArgumentError do
      create_resource :testing, tickets: -1
    end
    assert_raises ArgumentError do
      create_resource :testing, tickets: 1_000_000
    end
    assert_raises TypeError do
      create_resource :testing, tickets: 2, permissions: 'test'
    end
  end

  def test_initialize_with_float
    resource = create_resource :testing, tickets: 1.0
    assert resource
    assert_equal 1, resource.tickets
  end

  def test_max_tickets
    assert Semian::MAX_TICKETS > 0
  end

  def test_register
    create_resource :testing, tickets: 2
  end

  def test_register_with_no_tickets_raises
    assert_raises Semian::SyscallError do
      create_resource :testing, tickets: 0
    end
  end

  def test_acquire
    acquired = false
    resource = create_resource :testing, tickets: 1
    resource.acquire { acquired = true }
    assert acquired
  end

  def test_acquire_return_val
    resource = create_resource :testing, tickets: 1
    val = resource.acquire { 1234 }
    assert_equal 1234, val
  end

  def test_acquire_timeout
    resource = create_resource :testing, tickets: 1, timeout: 0.05

    acquired = false
    m = Monitor.new
    cond = m.new_cond

    t = Thread.start do
      m.synchronize do
        cond.wait_until { acquired }
        assert_raises Semian::TimeoutError do
          resource.acquire { refute true }
        end
      end
    end

    resource.acquire do
      acquired = true
      m.synchronize { cond.signal }
      sleep 0.2
    end

    t.join

    assert acquired
  end

  def test_acquire_timeout_override
    resource = create_resource :testing, tickets: 1, timeout: 0.01

    acquired = false
    thread_acquired = false
    m = Monitor.new
    cond = m.new_cond

    t = Thread.start do
      m.synchronize do
        cond.wait_until { acquired }
        resource.acquire(timeout: 1) { thread_acquired = true }
      end
    end

    resource.acquire do
      acquired = true
      m.synchronize { cond.signal }
      sleep 0.2
    end

    t.join

    assert acquired
    assert thread_acquired
  end

  def test_acquire_with_fork
    resource = create_resource :testing, tickets: 2, timeout: 0.5

    resource.acquire do
      fork do
        resource.acquire do
          begin
            resource.acquire {}
          rescue Semian::TimeoutError
            exit! 100
          end
          exit! 0
        end
      end

      timeouts = Process.waitall.count { |s| s.last.exitstatus == 100 }
      assert_equal(1, timeouts)
    end
  end

  def test_acquire_releases_on_kill
    resource = create_resource :testing, tickets: 1, timeout: 0.1
    acquired = false

    # Ghetto process synchronization
    file = Tempfile.new('semian')
    path = file.path
    file.close!

    pid = fork do
      resource.acquire do
        FileUtils.touch(path)
        sleep 1000
      end
    end

    sleep 0.1 until File.exist?(path)
    assert_raises Semian::TimeoutError do
      resource.acquire {}
    end

    Process.kill("KILL", pid)
    resource.acquire { acquired = true }
    assert acquired

    Process.wait
  ensure
    FileUtils.rm_f(path) if path
  end

  def test_count
    resource = create_resource :testing, tickets: 2
    acquired = false

    resource.acquire do
      acquired = true
      assert_equal 1, resource.count
      assert_equal 2, resource.tickets
    end

    assert acquired
  end

  def test_sem_undo
    resource = create_resource :testing, tickets: 1

    # Ensure we don't hit ERANGE errors caused by lack of SEM_UNDO on semop* calls
    # by doing an acquire > SEMVMX (32767) times:
    #
    # See: http://lxr.free-electrons.com/source/ipc/sem.c?v=3.8#L419
    (1 << 16).times do # do an acquire 64k times
      resource.acquire do
        1
      end
    end
  end

  def test_destroy
    resource = create_resource :testing, tickets: 1
    resource.destroy
    assert_raises Semian::SyscallError do
      resource.acquire {}
    end
  end

  def test_permissions
    resource = create_resource :testing, permissions: 0600, tickets: 1
    semid = resource.semid
    `ipcs -s `.lines.each do |line|
      if /\s#{semid}\s/.match(line)
        assert_equal '600', line.split[3]
      end
    end

    resource = create_resource :testing, permissions: 0660, tickets: 1
    semid = resource.semid
    `ipcs -s `.lines.each do |line|
      if /\s#{semid}\s/.match(line)
        assert_equal '660', line.split[3]
      end
    end
  end

  def test_resize_tickets_increase
    resource = create_resource :testing, tickets: 1

    acquired = false
    m = Monitor.new
    cond = m.new_cond

    t = Thread.start do
      m.synchronize do
        cond.wait_until { acquired }

        resource = create_resource :testing, tickets: 5
        assert_equal 4, resource.count
      end
    end

    assert_equal 1, resource.count

    resource.acquire do
      acquired = true
      m.synchronize { cond.signal }
      sleep 0.2
    end

    t.join

    assert_equal 5, resource.count
  end

  def test_resize_tickets_decrease
    resource = create_resource :testing, tickets: 5

    acquired = false
    m = Monitor.new
    cond = m.new_cond

    t = Thread.start do
      m.synchronize do
        cond.wait_until { acquired }

        resource = create_resource :testing, tickets: 1
        assert_equal 0, resource.count
      end
    end

    assert_equal 5, resource.count

    resource.acquire do
      acquired = true
      m.synchronize { cond.signal }
      sleep 0.2
    end

    t.join

    assert_equal 1, resource.count
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
          create_resource(:testing, tickets: 5).acquire do |resource|
            assert resource.count < 5
            acquired = true
          end
          assert acquired
        end
      end
      children.compact!

      f.flock(File::LOCK_UN)

      children.delete(Process.wait) while children.any?

      assert_equal 5, create_resource(:testing, tickets: 0).count
    ensure
      f.close!
    end
  end

  def create_resource(*args)
    @resources ||= []
    resource = Semian::Resource.new(*args)
    @resources << resource
    resource
  end

  def destroy_resources
    return unless @resources
    @resources.each do |resource|
      begin
        resource.destroy
      rescue
        nil
      end
    end
    @resources = []
  end
end
