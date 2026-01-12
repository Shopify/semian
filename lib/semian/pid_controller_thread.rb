# frozen_string_literal: true

require "singleton"
require_relative "pid_controller"

module Semian
  class PIDControllerThread
    include Singleton

    @stopped = true
    @update_thread = nil
    @@circuit_breakers = Concurrent::Map.new
    @@sliding_interval = 1

    # As per the singleton pattern, this is called only once
    def initialize
      @stopped = false

      update_proc = proc do
        loop do
          break if @stopped

          wait_for_window

          # Update PID controller state for each registered circuit breaker
          @@circuit_breakers.each do |name, circuit_breaker|
            circuit_breaker.pid_controller_update
          end
        rescue => e
          Semian.logger&.warn("[#{@name}] PID controller update thread error: #{e.message}")
        end
      end

      @update_thread = if Fiber.scheduler
        Fiber.schedule(&update_proc)
      else
        Thread.new(&update_proc)
      end
    end

    def register_resource(circuit_breaker)
      # Track every registered circuit breaker in a Concurrent::Map
      @@circuit_breakers[circuit_breaker.name] = circuit_breaker
    end

    def unregister_resource(circuit_breaker)
      @@circuit_breakers.delete(circuit_breaker.name)
      stop if @@circuit_breakers.empty?
    end

    private

    def wait_for_window
      Kernel.sleep(@@sliding_interval)
    end

    def stop
      @stopped = true
      if @update_thread.is_a?(Thread)
        @update_thread.kill
        @update_thread = nil
      end
    end
  end
end
