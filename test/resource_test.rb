require 'test_helper'

class TestResource < Minitest::Test
  include ResourceHelper

  # Time epsilon to account for super fast machines
  EPSILON = 0.1

  def setup
    Semian.destroy(:testing)
  rescue
    nil
  end

  def teardown
    destroy_resources
    signal_workers('KILL')
    Process.waitall
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
    expected_warning = /semian ticket value 1\.000000 is a float, converting to fixnum/
    with_fake_std_error(warn_message: expected_warning) do
      resource = create_resource :testing, tickets: 1.0
      assert resource
      assert_equal 1, resource.tickets
    end
  end

  def test_max_tickets
    assert Semian::MAX_TICKETS > 0
  end

  def test_register
    create_resource :testing, tickets: 2
  end

  def test_register_with_quota
    create_resource :testing, quota: 0.5
  end

  def test_unregister_past_0
    workers = 10
    resource = Semian.register(:testing, tickets: workers * 2, error_threshold: 0, error_timeout: 0, success_threshold: 0)

    fork_workers(count: workers, tickets: 0, timeout: 0.5, wait_for_timeout: true) do
      Semian.unregister(:testing)
    end

    Semian.unregister(:testing)
    signal_workers('TERM')
    Process.waitall

    assert_equal 0, resource.registered_workers
  end

  def test_reset_registered_workers
    workers = 10
    resource = Semian.register(:testing, tickets: 1, error_threshold: 0, error_timeout: 0, success_threshold: 0)

    fork_workers(count: workers - 1, tickets: 0, timeout: 0.5, wait_for_timeout: true)

    assert_equal workers, resource.registered_workers
    resource.bulkhead.reset_registered_workers!
    assert_equal 0, resource.registered_workers

    signal_workers('TERM')
    Process.waitall
    assert_equal 0, resource.registered_workers
  end

  def test_global_resource
    Semian.register_global_worker

    @workers = []
    4.times do
      @workers << fork do
        Semian.register_global_worker
        sleep
      end
    end

    sleep 2

    assert_equal 5, Semian.global_resource.registered_workers

    res1 = Semian::Resource.new(:mysql_shard_0, quota: 0.5, is_global: true)
    res2 = Semian::Resource.new(:mysql_shard_1, quota: 0.5, is_global: true)
    assert_equal 3, res1.tickets
    assert_equal 3, res2.tickets

    res3 = Semian::Resource.new(:mysql_shard_2, quota: 0.5)
    assert_equal 1, res3.tickets

    signal_workers('TERM')
    Process.waitall
  end

  def test_global_resource_raises_exception_if_global_worker_not_registered
    assert_raises ArgumentError do
      Semian::Resource.new(:mysql_shard_0, quota: 0.5, is_global: true)
    end

    Semian.register_global_worker
    Semian::Resource.new(:mysql_shard_0, quota: 0.5, is_global: true)
  end

  def test_exactly_one_register_with_quota
    r = Semian::Resource.instance(:testing, quota: 0.5)

    10.times do
      Semian::Resource.instance(:testing, quota: 0.5)
    end

    assert_equal 1, r.tickets
    r.destroy
  end

  def test_register_with_invalid_quota
    assert_raises ArgumentError do
      create_resource :testing, quota: 2.0
    end

    assert_raises ArgumentError do
      create_resource :testing, quota: 0
    end

    assert_raises ArgumentError do
      create_resource :testing, quota: -1.0
    end
  end

  def test_register_with_quota_and_tickets_raises
    assert_raises ArgumentError do
      create_resource :testing, tickets: 2, quota: 0.5
    end
  end

  def test_register_with_neither_quota_nor_tickets_raises
    assert_raises ArgumentError do
      Semian::Resource.new(:testing)
    end
  end

  def test_register_with_no_tickets_raises
    assert_raises Semian::SyscallError do
      create_resource :test_raises, tickets: 0
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
    fork_workers(count: 2, tickets: 1, timeout: 1, wait_for_timeout: true)
    signal_workers('TERM')
    timeouts = count_worker_timeouts
    assert 1, timeouts
  end

  def test_acquire_timeout_override
    fork_workers(count: 1, tickets: 1, timeout: 0.5, wait_for_timeout: true) do
      sleep 0.6
    end

    fork_workers(count: 1, tickets: 1, timeout: 1, wait_for_timeout: true)

    signal_workers('TERM')

    timeouts = count_worker_timeouts
    assert 0, timeouts
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
      timeouts = count_worker_timeouts

      assert_equal(1, timeouts)
    end
  end

  def test_quota_acquire
    quota = 0.5
    workers = 9

    resource = create_resource :testing, quota: quota, timeout: 0.1
    fork_workers(count: workers, quota: quota, wait_for_timeout: true)

    # Ensure that the number of tickets is correct and none are remaining
    assert_equal quota * (workers + 1), resource.tickets
    assert_equal 0, resource.count

    # Ensure that no more tickets may be allocated
    assert_raises Semian::TimeoutError do
      resource.acquire {}
    end

    signal_workers('TERM')

    # Ensure the correct number of processes timed out
    timeouts = count_worker_timeouts
    assert_equal workers - ((1 - quota) * workers).ceil, timeouts

    # Ensure that the tickets were released
    assert_equal resource.tickets, resource.count
  end

  def test_quota_increase
    quota = 0.5
    new_quota = 0.7
    workers = 20

    # Spawn some workers with an initial quota
    fork_workers(count: workers - 1, quota: quota, timeout: 0.5, wait_for_timeout: true)
    resource = create_resource :testing, quota: new_quota, timeout: 0.1

    assert_equal((workers * new_quota).ceil, resource.tickets)
  end

  def test_quota_decrease
    quota = 0.5
    new_quota = 0.3
    workers = 20

    # Spawn some workers with an initial quota
    fork_workers(count: workers - 1, quota: quota, timeout: 0.5, wait_for_timeout: true) do
      sleep 1
    end

    # We need to signal here to be able to enter the critical section
    signal_workers('TERM')
    resource = create_resource :testing, quota: new_quota, timeout: 0.1

    assert_equal((workers * new_quota).ceil, resource.tickets)
  end

  def test_quota_sets_tickets_from_workers
    quota = 0.5
    workers = 50

    resource = create_resource :testing, quota: quota, timeout: 0.1
    fork_workers(count: workers - 1, quota: quota, wait_for_timeout: true)

    assert_equal((workers * quota).ceil, resource.tickets)
  end

  def test_quota_adjust_tickets_on_new_workers
    quota = 0.5
    workers = 50

    resource = create_resource :testing, quota: quota, timeout: 0.1

    # Spawn some workers to get a basis for the quota
    fork_workers(count: workers - 1, quota: quota, wait_for_timeout: true)
    assert_equal((workers * quota).ceil, resource.tickets)

    # Add more workers to ensure the number of tickets increases
    fork_workers(count: workers - 1, quota: quota, wait_for_timeout: true)
    assert_equal((2 * workers * quota).ceil, resource.tickets)
  end

  def test_quota_adjust_tickets_on_kill
    quota = 0.5
    workers = 50

    resource = create_resource :testing, quota: quota, timeout: 0.1

    # Spawn some workers to get a basis for the quota
    fork_workers(count: workers - 1, quota: quota, wait_for_timeout: true)
    assert_equal((workers * quota).ceil, resource.tickets)

    # Signal and wait for the workers to quit
    signal_workers('KILL')
    Process.waitall

    # Number of tickets should be unchanged until resource is created
    assert_equal((workers * quota).ceil, resource.tickets)

    resource = create_resource :testing, quota: quota, timeout: 0.1
    assert_equal 1, resource.tickets
  end

  def test_quota_minimum_one_ticket
    resource = create_resource :testing, quota: 0.1, timeout: 0.1

    assert_equal 1, resource.tickets
  end

  def test_switch_static_tickets_to_quota
    workers = 20
    quota = 0.5

    # Fork a large number of workers using static ticket strategy
    fork_workers(count: workers - 1, tickets: 5, timeout: 0.5, wait_for_timeout: true) do
      sleep 1
    end

    # Signal static workers to shut down
    signal_workers('TERM')

    # Create a quota based worker, and ensure it accounts for the static
    # workers that haven't shut down yet
    resource = create_resource :testing, quota: quota, timeout: 0.1
    assert_equal((quota * workers).ceil, resource.tickets)

    # Let the static workers shut down
    sleep 2

    # Create a new resource, and ensure the static workers are no longer
    # accounted for
    resource = create_resource :testing, quota: quota, timeout: 0.1
    assert_equal((quota * 2).ceil, resource.tickets)
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

  def test_get_worker_count
    workers = rand(5..20)
    fork_workers(count: workers - 1, tickets: 1, timeout: 0.1, wait_for_timeout: true)
    resource = create_resource :testing, tickets: 1
    assert_equal(workers, resource.registered_workers)
  end

  def test_get_resource_key
    resource = create_resource :testing, tickets: 2
    assert_equal('0x874714f2', resource.key)
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

  def test_destroy_already_destroyed
    resource = create_resource :testing, tickets: 1
    100.times do
      resource.destroy
    end
  end

  def test_permissions
    resource = create_resource :testing, permissions: 0o600, tickets: 1
    semid = resource.semid
    `ipcs -s`.lines.each do |line|
      if /\s#{semid}\s/.match(line)
        assert_equal '600', line.split[3]
      end
    end

    resource = create_resource :testing, permissions: 0o660, tickets: 1
    semid = resource.semid
    `ipcs -s`.lines.each do |line|
      if /\s#{semid}\s/.match(line)
        assert_equal '660', line.split[3]
      end
    end
  end

  def test_resize_tickets_increase
    resource = create_resource :testing, tickets: 1

    assert_equal resource.tickets, resource.count
    assert_equal 1, resource.count

    fork_workers(count: 1, tickets: 5, timeout: 1, wait_for_timeout: true)

    signal_workers('TERM')
    Process.waitall

    assert_equal resource.tickets, resource.count
    assert_equal 5, resource.count
  end

  def test_resize_tickets_decrease
    resource = create_resource :testing, tickets: 5

    assert_equal resource.tickets, resource.count
    assert_equal 5, resource.count

    fork_workers(count: 1, tickets: 1, timeout: 1, wait_for_timeout: true)
    signal_workers('TERM')
    Process.waitall

    assert_equal resource.tickets, resource.count
    assert_equal 1, resource.count
  end

  def test_resize_tickets_decrease_with_fork
    tickets = 10
    workers = 50

    resource = create_resource :testing, tickets: tickets

    # Need to have the processes sleep for a bit after they are signalled to die
    fork_workers(count: workers, tickets: 0, wait_for_timeout: true) do
      sleep 2
    end

    assert_equal(tickets, resource.tickets)
    assert_equal(0, resource.count)

    # Signal the workers to quit
    signal_workers('TERM')

    # Request the ticket count be adjusted immediately
    # This should only return once the ticket count has been adjusted
    # This is sort of racey, because it's waiting on enough workers to quit
    # So that it has room to adjust the ticket count to the desired value.
    # This must happen in less than 5 seconds, or an internal timeout occurs.
    resource = create_resource :testing, tickets: (tickets / 2).floor

    # Immediately on the above call returning, the tickets should be correct
    assert_equal((tickets / 2).floor, resource.tickets)

    # Wait for all other processes to quit
    Process.waitall
  end

  def test_multiple_register_with_fork
    count = 5
    tickets = 5

    fork_workers(resource: :testing, count: count, tickets: tickets, wait_for_timeout: true)
    assert_equal 5, create_resource(:testing, tickets: 0).tickets
    assert_equal 0, create_resource(:testing, tickets: 0).count

    signal_workers('TERM')
    timeouts = count_worker_timeouts

    assert_equal 5, create_resource(:testing, tickets: 0).count
    assert_equal 0, timeouts
  end

  def create_resource(name, **kwargs)
    @resources ||= []
    resource = Semian::Resource.new(name, **kwargs)
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

  # Utility function to test with multiple processes
  # In particular, this is necessary to ensure handling of unique PIDs is correct,
  # which is key to functionality that is utilized like SEM_UNDO
  # Active workers are accumulated in the instance variable @workers,
  # and workers must be cleaned up between tests by the teardown script
  # An exit value of 100 is to keep track of timeouts, 0 for success.
  def fork_workers(count:, resource: :testing, quota: nil, tickets: nil, timeout: 0.1, wait_for_timeout: false)
    fail 'Must provide at least one of tickets or quota' unless tickets || quota

    @workers ||= []
    count.times do
      @workers << fork do
        begin
          resource = Semian::Resource.new(resource.to_sym, quota: quota, tickets: tickets, timeout: timeout)

          Signal.trap('TERM') do
            yield if block_given?
            exit! 0
          end

          # Hold the resource until signalled
          resource.acquire do
            sleep
          end
        rescue Semian::TimeoutError
          Signal.trap('TERM') do
            # Still sleep (in the yield) to avoid SIGCHLD, which makes semtimedop get interrupted
            yield if block_given?
            exit! 100
          end
          sleep
        rescue => e
          puts "Unhandled exception occurred in worker"
          puts e
          exit! 2
        end
      end
    end
    sleep((count / 2.0).ceil * timeout + EPSILON) if wait_for_timeout # give time for threads to timeout
  end

  def count_worker_timeouts
    Process.waitall.count { |s| s.last.exitstatus == 100 }
  end

  # Signals all workers
  def signal_workers(signal, delete: true)
    return unless @workers
    @workers.each do |worker|
      begin
        Process.kill(signal, worker)
      rescue
        nil
      end
    end
    @workers = [] if delete
  end

  class FakeStdErr
    attr_accessor :messages

    def initialize
      @messages = []
    end

    def write(msg)
      @messages << msg
    end

    def flush
    end
  end

  def with_fake_std_error(warn_message: nil)
    original_stderr = $stderr
    fake_std_err = FakeStdErr.new
    $stderr = fake_std_err
    yield
    if warn_message
      assert_match warn_message, fake_std_err.messages[0]
    end
  ensure
    $std_err = original_stderr # rubocop:disable GlobalVars
  end
end
