# frozen_string_literal: true

require "singleton"
require_relative "pid_controller"

module Semian
  class PIDControllerThread
    include Singleton

    def initialize
      Semian.logger.info("Thread initialized from #{caller}")
      @stopped = true
      @update_thread = nil
      @circuit_breakers = Concurrent::Map.new
      @sliding_interval = ENV.fetch("SEMIAN_ADAPTIVE_CIRCUIT_BREAKER_SLIDING_INTERVAL", 1).to_i
    end

    # As per the singleton pattern, this is called only once
    def start
      Semian.logger.info("Thread start called from #{caller}")
      @stopped = false

      update_proc = proc do
        loop do
          Semian.logger.info("PIDControllerThread Step1")
          break if @stopped

          Semian.logger.info("PIDControllerThread Step2")

          wait_for_window
          Semian.logger.info("PIDControllerThread Step3")

          # Update PID controller state for each registered circuit breaker
          @circuit_breakers.each do |_, circuit_breaker|
            circuit_breaker.pid_controller_update
          end
          Semian.logger.info("PIDControllerThread Step4")
        rescue => e
          Semian.logger.info("PIDControllerThread Step5")
          Semian.logger&.warn("PID controller update thread error: #{e.message}")
          Semian.logger.info("PIDControllerThread Step6")
        end
        Semian.logger.info("PIDControllerThread Step7")
      end

      @update_thread = Thread.new(&update_proc)
    end

    def stop
      Semian.logger.info("Thread stop called from #{caller}")
      @stopped = true
      @update_thread&.kill
      @update_thread = nil
    end

    def register_resource(circuit_breaker)
      # Track every registered circuit breaker in a Concurrent::Map
      Semian.logger.info("Thread register called with resource #{circuit_breaker.name} from #{caller}")

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
      Semian.logger.info("Thread unregister called with resource #{circuit_breaker.name} from #{caller}")

      @circuit_breakers.delete(circuit_breaker.name)

      # Stop the thread if there are no more circuit breakers
      if @circuit_breakers.empty?
        stop
      end
    end

    def wait_for_window
      Kernel.sleep(@sliding_interval)
    end
  end
end
