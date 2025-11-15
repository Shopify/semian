# frozen_string_literal: true

require "thread"

module Semian
  # A sliding window that stores timestamped observations
  # and automatically removes old observations based on a time window
  class TimestampedSlidingWindow
    attr_reader :window_size, :observations

    def initialize(window_size:)
      @window_size = window_size # in seconds
      @observations = []
      @lock = Mutex.new
    end

    # Add an observation with current timestamp
    # Note: We don't cleanup old observations here for performance reasons.
    # Cleanup happens lazily when reading data (get_counts, calculate_error_rate, etc.)
    # This is much more efficient under high write volume with infrequent reads.
    def add_observation(type, timestamp = nil)
      timestamp ||= current_time

      @lock.synchronize do
        @observations << { type: type, timestamp: timestamp }
      end
    end

    # Get counts of each type in the current window
    def get_counts(current_timestamp = nil)
      current_timestamp ||= current_time

      @lock.synchronize do
        cleanup_old_observations(current_timestamp)

        counts = { success: 0, error: 0, rejected: 0 }
        @observations.each do |obs|
          counts[obs[:type]] += 1 if obs[:type]
        end
        counts
      end
    end

    # Calculate error rate for the current window
    def calculate_error_rate(current_timestamp = nil)
      counts = get_counts(current_timestamp)
      total_requests = counts[:success] + counts[:error]
      return 0.0 if total_requests == 0

      counts[:error].to_f / total_requests
    end

    # Get all observations within the window
    def get_observations_in_window(current_timestamp = nil)
      current_timestamp ||= current_time

      @lock.synchronize do
        cleanup_old_observations(current_timestamp)
        @observations.dup
      end
    end

    # Clear all observations
    def clear
      @lock.synchronize do
        @observations.clear
      end
    end

    # Get the size of current observations
    def size
      @lock.synchronize do
        cleanup_old_observations
        @observations.size
      end
    end

    private

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Remove observations older than window_size seconds
    def cleanup_old_observations(current_timestamp = nil)
      current_timestamp ||= current_time
      cutoff_time = current_timestamp - @window_size

      @observations.reject! { |obs| obs[:timestamp] < cutoff_time }
    end
  end

  # Thread-safe version is already thread-safe by default
  # but we keep this for compatibility
  class ThreadSafeTimestampedSlidingWindow < TimestampedSlidingWindow
  end
end
