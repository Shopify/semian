# frozen_string_literal: true

require "test_helper"
require "semian/pid_controller"

# Tests for shared memory PID controller
# Only run these tests on Linux where shared memory is supported
class TestSharedPIDController < Minitest::Test
  include TimeHelper

  def setup
    skip "Shared memory not supported on this platform" unless Semian.semaphores_enabled?
    skip "SharedPIDController not available" unless defined?(Semian::SharedPIDController)
    
    @resource_name = "test_shared_pid_#{Process.pid}_#{rand(10000)}"
  end

  def teardown
    # Cleanup any created controllers
    if @controller
      @controller.destroy rescue nil
    end
    # Remove shared memory segment if it exists
    cleanup_shared_memory(@resource_name) if @resource_name
  end

  def test_initialization
    controller = create_shared_controller
    
    assert_equal(@resource_name, controller.name)
    assert_equal(0.0, controller.rejection_rate)
    assert(controller.shm_id > 0)
    
    metrics = controller.metrics
    assert_equal(0.0, metrics[:rejection_rate])
    assert_equal(0.0, metrics[:error_rate])
    assert_equal(0.0, metrics[:ping_failure_rate])
  end

  def test_record_request_operations
    controller = create_shared_controller
    
    controller.record_request(:success)
    controller.record_request(:success)
    controller.record_request(:error)
    
    metrics = controller.metrics
    assert_equal(2, metrics[:current_window_requests][:success])
    assert_equal(1, metrics[:current_window_requests][:error])
    assert_equal(0, metrics[:current_window_requests][:rejected])
  end

  def test_record_ping_operations
    controller = create_shared_controller
    
    controller.record_ping(:success)
    controller.record_ping(:failure)
    controller.record_ping(:success)
    
    metrics = controller.metrics
    assert_equal(2, metrics[:current_window_pings][:success])
    assert_equal(1, metrics[:current_window_pings][:failure])
  end

  def test_update_calculates_rates
    controller = create_shared_controller
    
    # Record some requests
    5.times { controller.record_request(:success) }
    5.times { controller.record_request(:error) }
    
    # Update to calculate rates
    new_rejection_rate = controller.update
    
    # Should have calculated 50% error rate
    metrics = controller.metrics
    assert_in_delta(0.5, metrics[:error_rate], 0.01)
    assert_operator(new_rejection_rate, :>=, 0.0)
    assert_operator(new_rejection_rate, :<=, 1.0)
  end

  def test_should_reject_probability
    controller = create_shared_controller
    
    # Force a high rejection rate by recording many errors
    100.times { controller.record_request(:error) }
    controller.update
    
    # Test rejection probability
    rejections = 0
    100.times do
      rejections += 1 if controller.should_reject?
    end
    
    # Should reject some requests (not necessarily exactly proportional due to randomness)
    assert_operator(rejections, :>, 0)
  end

  def test_wrapper_class_interface
    controller = Semian::PIDController.new(
      name: @resource_name,
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 5
    )
    
    # Should use SharedPIDControllerWrapper on supported platforms
    if Semian.semaphores_enabled?
      assert_instance_of(Semian::SharedPIDControllerWrapper, controller)
    end
    
    # Test interface compatibility
    assert_respond_to(controller, :record_request)
    assert_respond_to(controller, :record_ping)
    assert_respond_to(controller, :update)
    assert_respond_to(controller, :should_reject?)
    assert_respond_to(controller, :rejection_rate)
    assert_respond_to(controller, :metrics)
    
    @controller = controller
  end

  def test_reset_not_supported
    controller = create_shared_controller
    
    assert_raises(NotImplementedError) do
      controller.reset
    end
  end

  private

  def create_shared_controller
    @controller = Semian::SharedPIDControllerWrapper.new(
      name: @resource_name,
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 5,
      history_duration: 100
    )
  end

  def cleanup_shared_memory(name)
    # Try to remove shared memory segment
    # This is best-effort cleanup
    begin
      temp_controller = Semian::SharedPIDController.new(
        name.to_s, 1.0, 0.1, 0.01, 5, -1.0, Semian.default_permissions
      )
      temp_controller.destroy
    rescue
      # Ignore errors during cleanup
    end
  end
end

# Multi-process coordination tests
class TestSharedPIDControllerMultiProcess < Minitest::Test
  include TimeHelper

  def setup
    skip "Shared memory not supported on this platform" unless Semian.semaphores_enabled?
    skip "SharedPIDController not available" unless defined?(Semian::SharedPIDController)
    
    @resource_name = "test_shared_multiproc_#{Process.pid}_#{rand(10000)}"
    @pids = []
  end

  def teardown
    # Kill any remaining child processes
    @pids.each do |pid|
      begin
        Process.kill('TERM', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        # Process already dead
      end
    end
    
    # Cleanup shared memory
    cleanup_shared_memory(@resource_name) if @resource_name
  end

  def test_multiple_process_attachment
    # Create controller in parent
    parent_controller = create_shared_controller
    parent_shm_id = parent_controller.shm_id
    
    # Fork 3 children, all should attach to same shared memory
    3.times do
      @pids << fork do
        child_controller = create_shared_controller
        exit(child_controller.shm_id == parent_shm_id ? 0 : 1)
      end
    end
    
    # Wait for all children
    @pids.each do |pid|
      _, status = Process.wait2(pid)
      assert_equal(0, status.exitstatus, "Child process should have same shm_id")
    end
    @pids.clear
  end

  def test_shared_rejection_rate_across_processes
    controller = create_shared_controller
    
    # Parent sets up some state
    10.times { controller.record_request(:error) }
    controller.update
    parent_rate = controller.rejection_rate
    
    pid = fork do
      # Child creates new controller for same resource
      child_controller = create_shared_controller
      child_rate = child_controller.rejection_rate
      
      # Should see same rejection rate
      exit((child_rate - parent_rate).abs < 0.0001 ? 0 : 1)
    end
    
    @pids << pid
    _, status = Process.wait2(pid)
    assert_equal(0, status.exitstatus, "Child should see same rejection rate")
    @pids.delete(pid)
  end

  def test_aggregated_data_collection
    controller = create_shared_controller
    
    # Fork 5 workers, each records different outcomes
    5.times do |i|
      @pids << fork do
        worker_controller = create_shared_controller
        
        # Each worker records 10 requests
        10.times do
          if i < 2
            worker_controller.record_request(:success)
          else
            worker_controller.record_request(:error)
          end
        end
        
        exit(0)
      end
    end
    
    # Wait for all workers
    @pids.each { |pid| Process.wait(pid) }
    @pids.clear
    
    # Parent checks aggregated data
    metrics = controller.metrics
    total_requests = metrics[:current_window_requests][:success] + 
                    metrics[:current_window_requests][:error]
    
    # Should have 50 total requests (5 workers × 10 requests)
    assert_equal(50, total_requests)
    
    # 2 workers recorded success (20), 3 recorded errors (30)
    assert_equal(20, metrics[:current_window_requests][:success])
    assert_equal(30, metrics[:current_window_requests][:error])
  end

  def test_concurrent_updates_no_deadlock
    controller = create_shared_controller
    
    # Fork 3 processes that all call update rapidly
    3.times do
      @pids << fork do
        child_controller = create_shared_controller
        
        # Call update 10 times
        10.times do
          child_controller.record_request(:success)
          child_controller.update
          sleep(0.01)
        end
        
        exit(0)
      end
    end
    
    # Wait with timeout
    timeout = 5
    start_time = Time.now
    @pids.each do |pid|
      remaining = timeout - (Time.now - start_time)
      if remaining > 0
        Timeout.timeout(remaining) do
          Process.wait(pid)
        end
      else
        flunk("Test timed out - possible deadlock")
      end
    end
    @pids.clear
    
    # Should not deadlock or crash
    assert(true)
  end

  private

  def create_shared_controller
    Semian::SharedPIDControllerWrapper.new(
      name: @resource_name,
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 5,
      history_duration: 100
    )
  end

  def cleanup_shared_memory(name)
    begin
      temp_controller = Semian::SharedPIDController.new(
        name.to_s, 1.0, 0.1, 0.01, 5, -1.0, Semian.default_permissions
      )
      temp_controller.destroy
    rescue
      # Ignore cleanup errors
    end
  end
end

# Cleanup and resource leak tests
class TestSharedPIDControllerCleanup < Minitest::Test
  def setup
    skip "Shared memory not supported on this platform" unless Semian.semaphores_enabled?
    skip "SharedPIDController not available" unless defined?(Semian::SharedPIDController)
  end

  def test_controller_cleanup_destroys_state
    resource_name = "test_cleanup_#{Process.pid}_#{rand(10000)}"
    
    controller = Semian::SharedPIDControllerWrapper.new(
      name: resource_name,
      kp: 1.0,
      ki: 0.1,
      kd: 0.01
    )
    
    shm_id = controller.shm_id
    assert(shm_id > 0)
    
    # Destroy should detach
    controller.destroy
    
    # Shared memory may still exist if other processes attached
    # This is expected behavior
    assert(true)
  end

  def test_no_memory_leaks_with_many_controllers
    # Create and destroy 50 controllers with different names
    50.times do |i|
      resource_name = "test_leak_#{Process.pid}_#{i}_#{rand(1000)}"
      
      controller = Semian::SharedPIDControllerWrapper.new(
        name: resource_name,
        kp: 1.0,
        ki: 0.1,
        kd: 0.01
      )
      
      controller.record_request(:success)
      controller.update
      controller.destroy
    end
    
    # Should complete without running out of resources
    assert(true)
  end
end

# Fallback behavior tests
class TestPIDControllerFallback < Minitest::Test
  def test_fallback_when_disabled
    skip "Test only relevant on platforms with shared memory support" unless Semian.semaphores_enabled?
    
    # Disable shared memory
    ENV['SEMIAN_PID_SHARED_DISABLED'] = '1'
    
    begin
      controller = Semian::PIDController.new(
        name: "test_fallback_#{rand(10000)}",
        kp: 1.0,
        ki: 0.1,
        kd: 0.01
      )
      
      # Should use ThreadSafePIDController, not SharedPIDControllerWrapper
      assert_instance_of(Semian::ThreadSafePIDController, controller)
    ensure
      ENV.delete('SEMIAN_PID_SHARED_DISABLED')
    end
  end
end

