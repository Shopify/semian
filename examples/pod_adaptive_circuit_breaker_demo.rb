#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "semian"
require "semian/pod_pid"
require "async"
require "async/bus/server"

NUM_WORKERS = 4
PHASES = [
  { name: "Phase 1: Healthy Service", count: 100, success_rate: 1.0 },
  { name: "Phase 2: Degraded Service", count: 200, success_rate: 0.5 },
  { name: "Phase 3: Failing Service", count: 200, success_rate: 0.0 },
  { name: "Phase 4: Service Recovery", count: 300, success_rate: 1.0 },
].freeze

def run_worker(worker_id, phase_pipe_read, result_pipe_write)
  Sync do |task|
    client = Semian::PodPID::Client.new
    client.connect

    result_pipe_write.puts("READY")

    while (line = phase_pipe_read.gets)
      phase = line.strip.split(",")
      break if phase[0] == "DONE"

      count = phase[1].to_i
      success_rate = phase[2].to_f

      stats = { success: 0, error: 0, rejected: 0 }

      count.times do |i|
        task.sleep(0.001) if (i % 10).zero?

        if client.should_reject?("mysql")
          client.record_observation("mysql", :rejected)
          stats[:rejected] += 1
        elsif rand < success_rate
          client.record_observation("mysql", :success)
          stats[:success] += 1
        else
          client.record_observation("mysql", :error)
          stats[:error] += 1
        end
      end

      task.sleep(0.1)
      result_pipe_write.puts("#{stats[:success]},#{stats[:error]},#{stats[:rejected]},#{client.rejection_rate("mysql")}")
    end

    client.disconnect
  end
  exit!(0)
end

puts "=== Pod Adaptive Circuit Breaker Demo (Multi-Process) ===\n\n"

server_ready_read, server_ready_write = IO.pipe

server_pid = fork do
  server_ready_read.close

  Sync do |task|
    state_service = Semian::PodPID::StateService.new(
      kp: Semian::DEFAULT_PID_CONFIG[:kp],
      ki: Semian::DEFAULT_PID_CONFIG[:ki],
      kd: Semian::DEFAULT_PID_CONFIG[:kd],
      window_size: Semian::DEFAULT_PID_CONFIG[:window_size],
      sliding_interval: Semian::DEFAULT_PID_CONFIG[:sliding_interval],
      initial_error_rate: Semian::DEFAULT_PID_CONFIG[:initial_error_rate],
    )

    controller = Semian::PodPID::Controller.new(state_service)
    server = Async::Bus::Server.new

    task.async do
      server.accept do |connection|
        connection.bind(:pid_controller, controller)
      end
    end

    task.async do
      loop do
        task.sleep(0.05)
        state_service.update_all_resources
      end
    end

    server_ready_write.puts("READY")
    server_ready_write.close

    sleep
  end
end

server_ready_write.close
server_ready_read.gets
puts "PID state service started (PID: #{server_pid})\n\n"

workers = []
phase_pipes = []
result_pipes = []

NUM_WORKERS.times do |i|
  phase_read, phase_write = IO.pipe
  result_read, result_write = IO.pipe

  pid = fork do
    phase_write.close
    result_read.close
    run_worker(i + 1, phase_read, result_write)
  end

  phase_read.close
  result_write.close

  workers << pid
  phase_pipes << phase_write
  result_pipes << result_read
end

puts "Waiting for #{NUM_WORKERS} worker processes to connect..."
result_pipes.each(&:gets)
puts "All workers connected!\n\n"

PHASES.each do |phase|
  puts "#{phase[:name]} (#{phase[:count]} requests per worker)"
  puts "-" * 50

  phase_pipes.each do |pipe|
    pipe.puts("PHASE,#{phase[:count]},#{phase[:success_rate]}")
  end

  total = { success: 0, error: 0, rejected: 0 }
  rates = []

  result_pipes.each_with_index do |pipe, i|
    result = pipe.gets.strip.split(",")
    total[:success] += result[0].to_i
    total[:error] += result[1].to_i
    total[:rejected] += result[2].to_i
    rates << result[3].to_f
    puts "  Worker #{i + 1} (PID #{workers[i]}): #{result[0]} success, #{result[1]} errors, #{result[2]} rejected, rate=#{(result[3].to_f * 100).round(2)}%"
  end

  puts "  Total: #{total[:success]} success, #{total[:error]} errors, #{total[:rejected]} rejected"
  puts "  All workers synchronized: #{rates.uniq.size == 1}\n\n"
end

puts "=== Demo Complete ===\n"

phase_pipes.each do |pipe|
  pipe.puts("DONE")
  pipe.close
end
result_pipes.each(&:close)

sleep(0.5)

(workers + [server_pid]).each do |pid|
  Process.kill("KILL", pid)
rescue
  nil
end

Process.waitall
