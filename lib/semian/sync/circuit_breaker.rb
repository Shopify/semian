# frozen_string_literal: true

# Semian::Sync::CircuitBreaker - Circuit breaker with server-delegated state
#
# Same interface as Semian::CircuitBreaker but delegates state to a central server:
#   - Reports errors/successes to CircuitBreakerServer via Client
#   - Receives state broadcasts from server
#   - Caches state locally for fast access
#
# Used automatically when registering with sync_scope: :shared:
#
#   Semian.register(:mysql_primary,
#     error_threshold: 3, error_timeout: 10, success_threshold: 2,
#     sync_scope: :shared
#   )

require_relative "client"

module Semian
  module Sync
    class CircuitBreaker
      attr_reader :name, :half_open_resource_timeout, :error_timeout, :last_error

      def initialize(name, exceptions:, success_threshold:, error_threshold:,
        error_timeout:, half_open_resource_timeout: nil, **_options)
        @name = name.to_sym
        @exceptions = Array(exceptions) + [::Semian::BaseError]
        @error_threshold = error_threshold
        @error_timeout = error_timeout
        @success_threshold = success_threshold
        @half_open_resource_timeout = half_open_resource_timeout
        @last_error = nil

        # Local state cache - updated by server broadcasts
        @state = :closed

        setup_sync!
      end

      # Execute block with circuit breaker protection. Raises OpenCircuitError if open.
      def acquire(resource = nil, &block)
        raise OpenCircuitError unless request_allowed?

        result = nil
        begin
          result = maybe_with_half_open_resource_timeout(resource, &block)
        rescue *@exceptions => error
          if !error.respond_to?(:marks_semian_circuits?) || error.marks_semian_circuits?
            mark_failed(error)
          end
          raise error
        else
          mark_success
        end
        result
      end

      def request_allowed?
        refresh_state_if_stale
        closed? || half_open?
      end

      def mark_failed(error)
        @last_error = error
        timestamp = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Client.report_error_async(@name, timestamp)
      end

      # Only meaningful when half-open.
      def mark_success
        return unless half_open?
        Client.report_success_async(@name)
      end

      def reset
        @state = :closed
        @last_error = nil
      end

      def destroy
        # No local resources to clean up
      end

      def closed?
        @state == :closed
      end

      def open?
        @state == :open
      end

      def half_open?
        @state == :half_open
      end

      # For compatibility with code expecting state object.
      def state
        self
      end

      def value
        @state
      end

      def in_use?
        !closed?
      end

      private

      def setup_sync!
        # Register with server
        result = Client.register_resource(@name, {
          error_threshold: @error_threshold,
          error_timeout: @error_timeout,
          success_threshold: @success_threshold,
        })

        # Set initial state from server
        if result && result[:state]
          update_state(result[:state].to_sym)
        end

        # Subscribe to state broadcasts
        Client.subscribe_to_updates(@name) do |new_state|
          update_state(new_state)
        end
      end

      def update_state(new_state)
        old_state = @state
        @state = new_state.to_sym

        if old_state != @state
          log_state_transition(old_state, @state)
          notify_state_transition(@state)
        end
      end

      def refresh_state_if_stale
        return unless open?

        # When open, check if server has transitioned to half_open
        server_state = Client.get_state(@name)
        if server_state && server_state != @state
          update_state(server_state)
        end
      end

      def log_state_transition(old_state, new_state)
        Semian.logger.info(
          "[Semian::Sync::CircuitBreaker] State transition from #{old_state} to #{new_state}. " \
          "name=\"#{@name}\"",
        )
      end

      def notify_state_transition(new_state)
        Semian.notify(:state_change, self, nil, nil, state: new_state)
      end

      def maybe_with_half_open_resource_timeout(resource, &block)
        if half_open? && @half_open_resource_timeout && resource.respond_to?(:with_resource_timeout)
          resource.with_resource_timeout(@half_open_resource_timeout) do
            block.call
          end
        else
          block.call
        end
      end
    end
  end
end
