# frozen_string_literal: true

require "singleton"
require_relative "pid_controller"

module Semian
  class PIDControllerThread
    include Singleton

    @stopped = true
    @update_thread = nil
    @workers = nil

    # As per the singleton pattern, this is called only once
    def initialize
      @stopped = false
      @workers = Concurrent::Map.new   # For thread-safety

      @update_thread = Thread.new do
        loop do
          break if @stopped
          puts "Thread iteration after 10 seconds"

          wait_for_window

          # Update state for each worker
          @workers.each do |name, worker|
            old_rejection_rate = worker.pid_controller.rejection_rate
            pre_update_metrics = worker.pid_controller.metrics

            worker.pid_controller.update
            new_rejection_rate = worker.pid_controller.rejection_rate

            check_and_notify_state_transition(old_rejection_rate, new_rejection_rate, pre_update_metrics)
            notify_metrics_update(name)
          end
        end
      rescue => e
        Semian.logger&.warn("[#{@name}] PID controller update thread error: #{e.message}")
      end
    end

    def stop
      @stopped = true
      @thread.kill
    end

    def start(name)
      # Creates a new worker named after the state of the resource
      @workers[name] = { WorkerState.new(name) }
    end

    private

    # Methods moved from adaptive_circuit_breaker.rb

    def wait_for_window
      sleep(10)
    end

    def check_and_notify_state_transition(old_rate, new_rate, pre_update_metrics)
      old_state = old_rate == 0.0 ? :closed : :open
      new_state = new_rate == 0.0 ? :closed : :open

      if old_state != new_state
        notify_state_transition(new_state)
        log_state_transition(old_state, new_state, new_rate, pre_update_metrics)
      end
    end

    def notify_state_transition(new_state)
      Semian.notify(:state_change, self, nil, nil, state: new_state)
    end

    def log_state_transition(old_state, new_state, rejection_rate, pre_update_metrics)
      requests = pre_update_metrics[:current_window_requests]

      str = "[#{self.class.name}] State transition from #{old_state} to #{new_state}."
      str += " success_count=#{requests[:success]}"
      str += " error_count=#{requests[:error]}"
      str += " rejected_count=#{requests[:rejected]}"
      str += " rejection_rate=#{(rejection_rate * 100).round(2)}%"
      str += " error_rate=#{(pre_update_metrics[:error_rate] * 100).round(2)}%"
      str += " ideal_error_rate=#{(pre_update_metrics[:ideal_error_rate] * 100).round(2)}%"
      str += " integral=#{pre_update_metrics[:integral].round(4)}"
      str += " name=\"#{@name}\""

      Semian.logger.info(str)
    end
  end

  class WorkerState
    attr_reader :name, :pid_controller
    
    def initialize(name, kp:, ki:, kd:, window_size:, sliding_interval:, implementation:, initial_error_rate:)
      @name = name
      @pid_controller = implementation::PIDController.new(
        kp: kp,
        ki: ki,
        kd: kd,
        window_size: window_size,
        sliding_interval: sliding_interval,
        implementation: implementation,
        initial_error_rate: initial_error_rate,
      )
    end
  end
end