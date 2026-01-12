# frozen_string_literal: true

require "singleton"
require_relative "pid_controller"

module Semian
  class PIDControllerThread
    include Singleton

    @stopped = true
    @update_thread = nil
    @workers = Concurrent::Map.new
    @sliding_interval = 1

    # As per the singleton pattern, this is called only once
    def initialize
      @stopped = false
      
      #@workers = Concurrent::Map.new   # For thread-safety

      @update_thread = Thread.new do
        loop do
          break if @stopped
          puts "Thread iteration after 10 seconds"

          wait_for_window

          # Update state for each worker
          @workers.each do |name, worker|
            worker.pid_controller_update
          end
        rescue => e
          Semian.logger&.warn("[#{@name}] PID controller update thread error: #{e.message}")
        end
      end
    end

    def stop
      @stopped = true
      @thread.kill
    end

    def self.register_resource(circuit_breaker)
      # Creates a new worker named after the state of the resource
      @workers[circuit_breaker.name] = circuit_breaker
      @sliding_interval = circuit_breaker.sliding_interval
    end

    private
    
    def wait_for_window
      Kernel.sleep(@sliding_interval)
    end
  end
end