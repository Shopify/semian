# frozen_string_literal: true

require "singleton"
require_relative "pid_controller"

module Semian
  class PIDControllerThread
    include Singleton

    def initialize
      @stopped = true
      @update_thread = nil
      @circuit_breakers = Concurrent::Map.new
      @sliding_interval = ENV.fetch("SEMIAN_ADAPTIVE_CIRCUIT_BREAKER_SLIDING_INTERVAL", 1).to_i
    end

    # As per the singleton pattern, this is called only once
    def start
      @stopped = false

      update_proc = proc do
        loop do
          break if @stopped

          wait_for_window

          # Update PID controller state for each registered circuit breaker
          @circuit_breakers.each do |_, circuit_breaker|
            circuit_breaker.pid_controller_update
          end
        rescue => e
          Semian.logger&.warn("[#{@name}] PID controller update thread error: #{e.message}")
        end
      end

      @update_thread = Thread.new(&update_proc)
    end

    def register_resource(circuit_breaker)
      # Track every registered circuit breaker in a Concurrent::Map

      # Start the thread if it's not already running
      if @circuit_breakers.empty? && @stopped
        start
      end

      # Add the circuit breaker to the map
      @circuit_breakers[circuit_breaker.name] = circuit_breaker
      self
    end

    def unregister_resource(circuit_breaker)
      # Remove the circuit breaker from the map
      @circuit_breakers.delete(circuit_breaker.name)

      # Stop the thread if there are no more circuit breakers
      if @circuit_breakers.empty?
        @stopped = true
        @update_thread.kill
      end
    end

    def wait_for_window
      Kernel.sleep(@sliding_interval)
    end
  end
end
