# frozen_string_literal: true

require "json"
require "time"

# Add lib to load path if not already there
lib_path = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)

require "semian/adapter"

module Semian
  module Experiments
    # TrafficReplayExperimentalResource replays real production traffic patterns from Grafana exports.
    # It simulates request latencies based on a timeline extracted from JSON log files,
    # allowing you to test how your system would behave during a real incident.
    class TrafficReplayExperimentalResource
      include Semian::Adapter

      attr_reader :name, :traffic_log_path, :timeout

      # Initialize the traffic replay resource
      # @param name [String] The identifier for this resource
      # @param traffic_log_path [String] Path to Grafana JSON export for traffic replay
      # @param timeout [Float, nil] Maximum time to wait for a request (in seconds). If nil, no timeout is enforced.
      # @param options [Hash] Additional Semian options
      def initialize(name:, traffic_log_path:, timeout: nil, **options)
        @name = name
        @traffic_log_path = traffic_log_path
        @timeout = timeout
        @raw_semian_options = options[:semian]

        # Parse the traffic log and build timeline
        @traffic_timeline = parse_traffic_log(@traffic_log_path)
        @service_start_time = Time.now

        puts "Traffic replay mode enabled. Timeline duration: #{@traffic_timeline.last[:offset].round(2)}s with #{@traffic_timeline.size} requests"
      end

      # Required by Adapter
      def semian_identifier
        @name.to_sym
      end

      # Simulate making a request that replays latency from the traffic log
      # @raises [TimeoutError] if the request would exceed the configured timeout
      # @raises [TrafficReplayCompleteError] if the timeline has been exceeded
      def request(&block)
        acquire_semian_resource(scope: :request, adapter: :experimental) do
          perform_request(&block)
        end
      end

      private

      def perform_request(&block)
        # Get latency from timeline based on elapsed time
        latency = get_latency_from_timeline

        # Check if we've exceeded the log timeline
        if latency.nil?
          puts "\n=== Traffic replay completed ==="
          puts "Service has been running longer than the traffic log timeline."
          puts "No more requests will be processed."
          raise TrafficReplayCompleteError, "Traffic replay has completed - timeline exceeded"
        end

        # Check if request would timeout
        if @timeout && latency > @timeout
          # Sleep for the timeout period, then raise exception
          sleep(@timeout) if @timeout > 0
          raise TimeoutError,
            "Request timed out after #{@timeout}s (would have taken #{latency.round(3)}s)"
        end

        # Simulate the request with calculated latency
        sleep(latency) if latency > 0

        if block_given?
          yield(latency)
        else
          { latency: latency }
        end
      end

      attr_reader :raw_semian_options

      def resource_exceptions
        [TimeoutError, TrafficReplayCompleteError]
      end

      # Parse the traffic log JSON file and build a timeline
      # @param file_path [String] Path to the Grafana JSON export
      # @return [Array<Hash>] Array of { offset: Float, latency: Float } sorted by offset
      def parse_traffic_log(file_path)
        unless File.exist?(file_path)
          raise ArgumentError, "Traffic log file not found: #{file_path}"
        end

        entries = []
        first_timestamp = nil

        File.foreach(file_path) do |line|
          line = line.strip
          next if line.empty?

          begin
            entry = JSON.parse(line)
            timestamp_str = entry["timestamp"]

            unless timestamp_str
              warn("Warning: Entry missing timestamp field, skipping")
              next
            end

            timestamp = Time.parse(timestamp_str)

            # Track the first timestamp to calculate offsets
            first_timestamp ||= timestamp

            # Calculate offset from start in seconds
            offset = timestamp - first_timestamp

            # Get latency in milliseconds, default to 0 if not present
            latency_ms = entry.dig("attrs.db.sql.total_duration_ms") || 0
            latency_seconds = latency_ms / 1000.0

            entries << { offset: offset, latency: latency_seconds }
          rescue JSON::ParserError => e
            warn("Warning: Failed to parse JSON line: #{e.message}")
            next
          rescue ArgumentError => e
            warn("Warning: Failed to parse timestamp: #{e.message}")
            next
          end
        end

        if entries.empty?
          raise ArgumentError, "No valid entries found in traffic log file: #{file_path}"
        end

        # Sort by offset to ensure timeline is in order
        entries.sort_by { |e| e[:offset] }
      end

      # Get latency for current elapsed time from the traffic timeline
      # @return [Float, nil] Latency in seconds, or nil if timeline exceeded
      def get_latency_from_timeline
        elapsed = Time.now - @service_start_time

        # Check if we've exceeded the timeline
        if elapsed > @traffic_timeline.last[:offset]
          return
        end

        # Find the entry with the closest offset to elapsed time
        # Using binary search would be more efficient, but linear search is simpler
        # and fine for most use cases
        closest_entry = @traffic_timeline.min_by { |entry| (entry[:offset] - elapsed).abs }

        closest_entry[:latency]
      end

      # Error classes specific to this adapter
      class CircuitOpenError < ::Semian::BaseError
        def initialize(semian_identifier, *args)
          super(*args)
          @semian_identifier = semian_identifier
        end
      end

      class ResourceBusyError < ::Semian::BaseError
        def initialize(semian_identifier, *args)
          super(*args)
          @semian_identifier = semian_identifier
        end
      end

      class TimeoutError < StandardError
        def marks_semian_circuits?
          true # This error should trigger circuit breaker
        end
      end

      class TrafficReplayCompleteError < StandardError
        def marks_semian_circuits?
          false # This is not a real error, just indicates replay is complete
        end
      end
    end
  end
end
