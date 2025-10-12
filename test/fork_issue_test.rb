# frozen_string_literal: true

require "test_helper"

class ForkIssueTest < Minitest::Test
  # i_suck_and_my_tests_are_order_dependent!

  def setup
    @workers = []
    Semian.destroy_all_resources
    cleanup_ipcs
  end

  def teardown
    @workers.each { |pid| Process.kill("KILL", pid) }
    @workers = []
  end

  def cleanup_ipcs
    # Clean up all semaphores to avoid accumulation
    %x(ipcs -s | grep #{ENV["USER"] || "root"} | awk '{print $2}' | xargs -n 1 ipcrm -s 2>/dev/null)
  end

  def test_fork_with_reset
    # will pass and print:
    # in parent - registered workers: 11
    # in parent - registered workers: 11
    # in parent - registered workers: 11
    # in parent - registered workers: 11
    # in parent - registered workers: 11
    # in parent - registered workers: 11
    # in parent - registered workers: 11
    # in parent - registered workers: 11
    # in parent - registered workers: 11
    # in parent - registered workers: 11
    # in parent after waitall - registered workers: 1
    resource_name = "32767mysql_readonly" + rand(1000000).to_s
    Semian.retrieve_or_register(
      resource_name,
      quota: 0.51,
      error_threshold: 1,
      error_timeout: 1,
      success_threshold: 1,
    )
    sem = Semian.resources.get(resource_name)
    10.times do
      @workers << fork do
        assert(Semian.resources[resource_name])
        Semian.reset!
        Semian.retrieve_or_register(
          resource_name,
          error_threshold: 1,
          error_timeout: 1,
          quota: 0.51,
          success_threshold: 1,
        )
        trap("TERM") { exit(0) }
        trap("INT") { exit(0) }
        loop do
          sleep(0.5)
        end
      end
    end

    # 10.times do
    #   puts "in parent - registered workers: #{parse_semaphore_value(ipcs_output, 3)}"
    #   sleep(0.5)
    # end

    # wait for all workers to do their thing
    sleep(5)
    current_workers = parse_semaphore_value(ipcs_output(sem.semid), 3)

    assert_equal(11, current_workers)

    @workers.each { |pid| Process.kill("TERM", pid) }
    @workers = []
    Process.waitall
    current_workers = parse_semaphore_value(ipcs_output(sem.semid), 3)

    assert_equal(1, current_workers)
    # puts "in parent after waitall - registered workers: #{parse_semaphore_value(ipcs_output(sem.semid), 3)}"
  end

  def test_fork_with_unregister_all_resources
    # will fail and print:

    #  in parent - registered workers: 1
    #  in parent - registered workers: 1
    #  in parent - registered workers: 1
    #  in parent - registered workers: 1
    #  in parent - registered workers: 1
    #  in parent - registered workers: 1
    #  in parent - registered workers: 1
    #  in parent - registered workers: 1
    #  in parent - registered workers: 1
    #  in parent - registered workers: 1
    #  F
    resource_name = "32767mysql_readonly" + rand(1000000).to_s
    Semian.retrieve_or_register(
      resource_name,
      quota: 0.51,
      error_threshold: 1,
      error_timeout: 1,
      success_threshold: 1,
    )
    sem = Semian.resources.get(resource_name)
    10.times do
      @workers << fork do
        # each worker will get a Semian.resources
        assert(Semian.resources[resource_name])

        # calling unregister_all_resources will:
        # - remove ruby references of all resources
        # - decrease the number of registered workers in the semaphore, which is racy with the forked workers
        Semian.unregister_all_resources
        Semian.retrieve_or_register(
          resource_name,
          error_threshold: 1,
          error_timeout: 1,
          quota: 0.51,
          success_threshold: 1,
        )
        trap("TERM") do
          puts "exiting: #{Process.pid}"
          exit(0)
        end
        trap("INT") { exit(0) }
        loop do
          sleep(0.5)
        end
      end
    end

    # 10.times do
    #   # puts "in parent - registered workers: #{parse_semaphore_value(ipcs_output(sem.semid), 3)}"
    #   sleep(0.5)
    # end

    # wait for all workers to do their thing
    sleep(5)
    current_workers = parse_semaphore_value(ipcs_output(sem.semid), 3)

    assert_equal(11, current_workers)
  end

  def test_fork_with_unregister_resources_with_sleep
    # same as test_fork_with_unregister_all_resources, but with a sleep in the worker. This fixes the race condition. \
    # But notice the assertion, assert_equal(10, current_workers). Each worker will unregister the inherited semaphore,
    # wait for a second so all workers catchup with unregister
    resource_name =  "32767mysql_readonly" + rand(1000000).to_s
    Semian.retrieve_or_register(
      resource_name,
      quota: 0.51,
      error_threshold: 1,
      error_timeout: 1,
      success_threshold: 1,
    )
    sem = Semian.resources.get(resource_name)
    10.times do
      @workers << fork do
        # each worker will get a Semian.resources
        assert(Semian.resources[resource_name])

        # calling unregister_all_resources will:
        # - remove ruby references of all resources
        # - decrease the number of registered workers in the semaphore, which is racy with the forked workers
        Semian.unregister_all_resources
        sleep(0.1)
        Semian.retrieve_or_register(
          resource_name,
          error_threshold: 1,
          error_timeout: 1,
          quota: 0.51,
          success_threshold: 1,
        )
        trap("TERM") do
          puts "exiting: #{Process.pid}"
          exit(0)
        end
        trap("INT") { exit(0) }
        loop do
          sleep(0.5)
        end
      end
    end

    #  10.times do
    #    puts "in parent - registered workers: #{parse_semaphore_value(ipcs_output(sem.semid), 3)}"
    #    sleep(0.5)
    #  end
    # wait for all workers to do their thing
    sleep(5)
    current_workers = parse_semaphore_value(ipcs_output(sem.semid), 3)

    assert_equal(10, current_workers)
  end

  def parse_semaphore_value(output, semnum = 0)
    if output.empty?
      return 0
    end

    lines = output.split("\n")
    lines.each do |line|
      if line.strip =~ /^#{semnum}\s+(\d+)/
        return ::Regexp.last_match(1).to_i
      end
    end
    puts "nil"
    nil
  end

  def ipcs_output(semid)
    %x(ipcs -si #{semid}).strip
  end
end
