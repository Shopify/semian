# frozen_string_literal: true

require_relative "../pid_controller"
require_relative "../simple_sliding_window"
require_relative "wal"

module Semian
  module PodPID
    class StateService
      attr_reader :resources, :config

      def initialize(
        kp:,
        ki:,
        kd:,
        window_size:,
        sliding_interval:,
        initial_error_rate:,
        wal_path: WAL::DEFAULT_PATH,
        on_rejection_rate_change: nil
      )
        @config = {
          kp: kp,
          ki: ki,
          kd: kd,
          window_size: window_size,
          sliding_interval: sliding_interval,
          initial_error_rate: initial_error_rate,
        }
        @resources = {}
        @mutex = Mutex.new
        @wal = WAL.new(wal_path)
        @on_rejection_rate_change = on_rejection_rate_change
        @running = false

        restore_from_wal
      end

      def record_observation(resource, outcome)
        controller = ensure_resource(resource)
        controller.record_request(outcome)
      end

      def rejection_rate(resource)
        controller = @resources[resource.to_s]
        controller&.rejection_rate || 0.0
      end

      def start_update_loop
        @running = true
        @update_thread = Thread.new do
          while @running
            sleep(@config[:sliding_interval])
            update_all_resources
          end
        end
      end

      def stop_update_loop
        @running = false
        @update_thread&.join(5)
        @update_thread = nil
      end

      def update_all_resources
        @mutex.synchronize do
          @resources.each do |name, controller|
            old_rate = controller.rejection_rate
            controller.update
            new_rate = controller.rejection_rate

            if old_rate != new_rate
              persist_state(name, controller)
              notify_rejection_rate_change(name, new_rate)
            end
          end
        end
      end

      def metrics(resource)
        controller = @resources[resource.to_s]
        controller&.metrics
      end

      private

      def ensure_resource(resource)
        name = resource.to_s
        @mutex.synchronize do
          @resources[name] ||= create_controller
        end
      end

      def create_controller
        Semian::ThreadSafe::PIDController.new(
          kp: @config[:kp],
          ki: @config[:ki],
          kd: @config[:kd],
          window_size: @config[:window_size],
          sliding_interval: @config[:sliding_interval],
          initial_error_rate: @config[:initial_error_rate],
          implementation: Semian::ThreadSafe,
        )
      end

      def restore_from_wal
        count = @wal.replay do |resource, state|
          controller = ensure_resource(resource)
          apply_state(controller, state)
        end
        @wal.truncate if count > 0
      end

      def apply_state(controller, state)
        controller.instance_variable_set(:@rejection_rate, state[:rejection_rate]) if state[:rejection_rate]
        controller.instance_variable_set(:@integral, state[:integral]) if state[:integral]
      end

      def persist_state(resource, controller)
        state = {
          rejection_rate: controller.rejection_rate,
          integral: controller.instance_variable_get(:@integral),
        }
        @wal.write(resource, state)
      end

      def notify_rejection_rate_change(resource, new_rate)
        @on_rejection_rate_change&.call(resource, new_rate)
      end
    end
  end
end
