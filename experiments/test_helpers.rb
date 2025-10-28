# frozen_string_literal: true

module Semian
  module Experiments
    # Test runner for circuit breaker experiments (both adaptive and classic)
    # Handles all the common logic: service creation, threading, monitoring, analysis, and visualization
    class CircuitBreakerTestRunner
      attr_reader :test_name, :resource_name, :error_phases, :phase_duration, :graph_title, :graph_filename

      def initialize(
        test_name:,
        resource_name:,
        error_phases:,
        phase_duration:,
        graph_title:,
        semian_config:,
        graph_filename: nil,
        num_threads: 60,
        requests_per_second_per_thread: 50,
        x_axis_label_interval: nil
      )
        @test_name = test_name
        @resource_name = resource_name
        @error_phases = error_phases
        @phase_duration = phase_duration
        @graph_title = graph_title
        @semian_config = semian_config
        @is_adaptive = semian_config[:adaptive_circuit_breaker] == true
        @graph_filename = graph_filename || "#{resource_name}.png"
        @num_threads = num_threads
        @requests_per_second_per_thread = requests_per_second_per_thread
        @x_axis_label_interval = x_axis_label_interval || phase_duration
        @test_duration = error_phases.length * phase_duration
      end

      def run
        setup_service
        setup_resources
        start_threads
        execute_phases
        wait_for_completion
        generate_analysis
        generate_visualization
      end

      private

      def setup_service
        puts "Creating mock service..."
        @service = MockService.new(
          endpoints_count: 50,
          min_latency: 0.01,
          max_latency: 0.3,
          distribution: {
            type: :log_normal,
            mean: 0.15,
            std_dev: 0.05,
          },
          error_rate: @error_phases.first,
          timeout: 5,
        )
      end

      def setup_resources
        puts "Initializing Semian resource..."
        begin
          init_resource = ExperimentalResource.new(
            name: @resource_name,
            service: @service,
            semian: @semian_config,
          )
          init_resource.request(0)
        rescue
          # Ignore any error, we just needed to trigger registration
        end
        puts "Resource initialized successfully.\n"
      end

      def start_threads
        @outcomes = {}
        @done = false
        @outcomes_mutex = Mutex.new
        @pid_snapshots = []
        @pid_mutex = Mutex.new
        @thread_timings = {}

        start_request_threads
        start_monitoring_thread if @is_adaptive
      end

      def start_request_threads
        total_rps = @num_threads * @requests_per_second_per_thread
        puts "Starting #{@num_threads} concurrent request threads (#{@requests_per_second_per_thread} requests/second each = #{total_rps} rps total)..."
        puts "Each thread will have its own adapter instance connected to the shared service...\n"

        @request_threads = []
        @num_threads.times do
          @request_threads << Thread.new do
            thread_id = Thread.current.object_id
            thread_resource = ExperimentalResource.new(
              name: @resource_name,
              service: @service,
              semian: @semian_config,
            )

            # Initialize timing for this thread
            @thread_timings[thread_id] = { total_time: 0.0, request_count: 0, samples: [] }

            sleep_interval = 1.0 / @requests_per_second_per_thread
            until @done
              sleep(sleep_interval)

              # Measure time spent making the request
              request_start = Time.now
              begin
                thread_resource.request(rand(@service.endpoints_count))

                @outcomes_mutex.synchronize do
                  current_sec = @outcomes[Time.now.to_i] ||= {
                    success: 0,
                    circuit_open: 0,
                    error: 0,
                  }
                  print("✓")
                  current_sec[:success] += 1
                end
              rescue ExperimentalResource::CircuitOpenError
                @outcomes_mutex.synchronize do
                  current_sec = @outcomes[Time.now.to_i] ||= {
                    success: 0,
                    circuit_open: 0,
                    error: 0,
                  }
                  print("⚡")
                  current_sec[:circuit_open] += 1
                end
              rescue ExperimentalResource::RequestError, ExperimentalResource::TimeoutError
                @outcomes_mutex.synchronize do
                  current_sec = @outcomes[Time.now.to_i] ||= {
                    success: 0,
                    circuit_open: 0,
                    error: 0,
                  }
                  print("✗")
                  current_sec[:error] += 1
                end
              ensure
                request_duration = Time.now - request_start
                timestamp = Time.now.to_i
                @thread_timings[thread_id][:total_time] += request_duration
                @thread_timings[thread_id][:request_count] += 1
                @thread_timings[thread_id][:samples] << { duration: request_duration, timestamp: timestamp }
              end
            end
          end
        end
      end

      def start_monitoring_thread
        puts "Starting PID monitoring thread..."
        @monitor_thread = Thread.new do
          sleep(1) # Wait for resource to register and first window to start

          until @done
            begin
              semian_resource = Semian[@resource_name.to_sym]
              if semian_resource&.circuit_breaker
                metrics = semian_resource.circuit_breaker.pid_controller.metrics

                # Calculate total time spent making requests across all threads
                total_request_time = @thread_timings.values.sum { |t| t[:total_time] }

                @pid_mutex.synchronize do
                  @pid_snapshots << {
                    timestamp: Time.now.to_i,
                    window: @pid_snapshots.length + 1,
                    current_error_rate: metrics[:error_rate],
                    ideal_error_rate: metrics[:ideal_error_rate],
                    error_metric: metrics[:error_metric],
                    rejection_rate: metrics[:rejection_rate],
                    integral: metrics[:integral],
                    derivative: metrics[:derivative],
                    previous_error: metrics[:previous_error],
                    total_request_time: total_request_time,
                  }
                end
              end
            rescue
              # Ignore errors
            end

            sleep(10) # Capture every window
          end
        end
      end

      def execute_phases
        puts "\n=== #{@test_name} (ADAPTIVE) ==="
        puts "Error rate: #{@error_phases.map { |r| "#{(r * 100).round(1)}%" }.join(" -> ")}"
        puts "Phase duration: #{@phase_duration} seconds (#{(@phase_duration / 60.0).round(1)} minutes) per phase"
        puts "Duration: #{@test_duration} seconds (#{(@test_duration / 60.0).round(1)} minutes)"
        puts "Starting test...\n"

        @start_time = Time.now

        @error_phases.each_with_index do |error_rate, idx|
          if idx > 0
            puts "\n=== Transitioning to #{(error_rate * 100).round(1)}% error rate ==="
            @service.set_error_rate(error_rate)
          end

          sleep(@phase_duration)
        end
      end

      def wait_for_completion
        @done = true
        puts "\nWaiting for all request threads to finish..."
        @request_threads.each(&:join)
        @monitor_thread.join if @is_adaptive
        @end_time = Time.now
      end

      def generate_analysis
        puts "\n\n=== Test Complete ==="
        puts "Actual duration: #{(@end_time - @start_time).round(2)} seconds"
        puts "\nGenerating analysis..."

        display_summary_statistics
        display_time_based_analysis
        display_thread_timing_statistics
        display_pid_controller_state
      end

      def display_summary_statistics
        total_success = @outcomes.values.sum { |data| data[:success] }
        total_circuit_open = @outcomes.values.sum { |data| data[:circuit_open] }
        total_error = @outcomes.values.sum { |data| data[:error] }
        total_requests = total_success + total_circuit_open + total_error

        puts "\n=== Summary Statistics ==="
        puts "Total Requests: #{total_requests}"
        puts "  Successes: #{total_success} (#{(total_success.to_f / total_requests * 100).round(2)}%)"
        puts "  Rejected: #{total_circuit_open} (#{(total_circuit_open.to_f / total_requests * 100).round(2)}%)"
        puts "  Errors: #{total_error} (#{(total_error.to_f / total_requests * 100).round(2)}%)"
      end

      def display_time_based_analysis
        bucket_size = @phase_duration
        num_buckets = (@test_duration / bucket_size.to_f).ceil

        puts "\n=== Time-Based Analysis (#{bucket_size}-second buckets) ==="
        (0...num_buckets).each do |bucket_idx|
          bucket_start = @outcomes.keys[0] + (bucket_idx * bucket_size)
          bucket_data = @outcomes.select { |time, _| time >= bucket_start && time < bucket_start + bucket_size }

          bucket_success = bucket_data.values.sum { |d| d[:success] }
          bucket_errors = bucket_data.values.sum { |d| d[:error] }
          bucket_circuit = bucket_data.values.sum { |d| d[:circuit_open] }
          bucket_total = bucket_success + bucket_errors + bucket_circuit

          bucket_time_range = "#{bucket_idx * bucket_size}-#{(bucket_idx + 1) * bucket_size}s"
          circuit_pct = bucket_total > 0 ? ((bucket_circuit.to_f / bucket_total) * 100).round(2) : 0
          error_pct = bucket_total > 0 ? ((bucket_errors.to_f / bucket_total) * 100).round(2) : 0
          status = bucket_circuit > 0 ? "⚡" : "✓"

          phase_error_rate = @error_phases[bucket_idx] || @error_phases.last
          phase_label = "[Target: #{(phase_error_rate * 100).round(1)}%]"

          puts "#{status} #{bucket_time_range} #{phase_label}: #{bucket_total} requests | Success: #{bucket_success} | Errors: #{bucket_errors} (#{error_pct}%) | Rejected: #{bucket_circuit} (#{circuit_pct}%)"
        end
      end

      def display_thread_timing_statistics
        return if @thread_timings.empty?

        puts "\n=== Thread Timing Statistics ==="

        # Calculate statistics across all threads
        total_times = @thread_timings.values.map { |t| t[:total_time] }
        request_counts = @thread_timings.values.map { |t| t[:request_count] }

        total_wall_time = @end_time - @start_time
        sum_thread_time = total_times.sum
        avg_thread_time = sum_thread_time / @thread_timings.size
        min_thread_time = total_times.min
        max_thread_time = total_times.max

        avg_requests = request_counts.sum / @thread_timings.size.to_f

        # Calculate utilization (time spent in requests vs wall clock time)
        avg_utilization = (avg_thread_time / total_wall_time * 100)

        puts "Total threads: #{@thread_timings.size}"
        puts "Test wall clock duration: #{total_wall_time.round(2)}s"
        puts "\nTime spent making requests per thread:"
        puts "  Min:     #{min_thread_time.round(2)}s"
        puts "  Max:     #{max_thread_time.round(2)}s"
        puts "  Average: #{avg_thread_time.round(2)}s"
        puts "  Total (all threads): #{sum_thread_time.round(2)}s"
        puts "\nThread utilization:"
        puts "  Average: #{avg_utilization.round(2)}% (time in requests / wall clock time)"
        puts "\nRequests per thread:"
        puts "  Average: #{avg_requests.round(0)} requests"
        puts "  Average time per request: #{(avg_thread_time / avg_requests).round(4)}s" if avg_requests > 0
      end

      def display_pid_controller_state
        return unless @is_adaptive

        if @pid_snapshots.empty?
          puts "\n⚠️  No PID snapshots collected"
          return
        end

        puts "\n=== PID Controller State Per Window ==="
        puts format("%-8s %-15s %-15s %-12s %-15s %-12s %-12s %-12s %-15s", "Window", "Current Err %", "Ideal Err %", "Error P", "Reject %", "Integral", "PrevError", "Derivative", "Total Req Time")
        puts "-" * 120

        @pid_snapshots.each do |snapshot|
          puts format(
            "%-8d %-15s %-15s %-12s %-15s %-12s %-12s %-12s %-15s",
            snapshot[:window],
            "#{(snapshot[:current_error_rate] * 100).round(2)}%",
            "#{(snapshot[:ideal_error_rate] * 100).round(2)}%",
            (snapshot[:error_metric] || 0).round(4),
            "#{(snapshot[:rejection_rate] * 100).round(2)}%",
            (snapshot[:integral] || 0).round(4),
            (snapshot[:previous_error] || 0).round(4),
            (snapshot[:derivative] || 0).round(4),
            "#{(snapshot[:total_request_time] || 0).round(2)}s",
          )
        end

        puts "\n📊 Key Observations:"
        puts "  - Windows captured: #{@pid_snapshots.length}"
        puts "  - Max rejection rate: #{(@pid_snapshots.map { |s| s[:rejection_rate] }.max * 100).round(2)}%"
        puts "  - Integral range: #{@pid_snapshots.map { |s| s[:integral] }.min.round(4)} to #{@pid_snapshots.map { |s| s[:integral] }.max.round(4)}"
      end

      def generate_visualization
        puts "\nGenerating visualization..."
        require "gruff"

        # Aggregate data into 10-second buckets for detailed visualization
        small_bucket_size = 10
        num_small_buckets = (@test_duration / small_bucket_size.to_f).ceil

        bucketed_data = []
        (0...num_small_buckets).each do |bucket_idx|
          bucket_start = @outcomes.keys[0] + (bucket_idx * small_bucket_size)
          bucket_end = bucket_start + small_bucket_size
          bucket_data = @outcomes.select { |time, _| time >= bucket_start && time < bucket_end }

          # Calculate sum of request durations from all samples in this bucket
          bucket_samples = []
          @thread_timings.each_value do |thread_data|
            bucket_samples.concat(thread_data[:samples].select { |s| s[:timestamp] >= bucket_start && s[:timestamp] < bucket_end })
          end

          sum_request_duration = bucket_samples.sum { |s| s[:duration] }

          bucketed_data << {
            success: bucket_data.values.sum { |d| d[:success] },
            circuit_open: bucket_data.values.sum { |d| d[:circuit_open] },
            error: bucket_data.values.sum { |d| d[:error] },
            sum_request_duration: sum_request_duration,
          }
        end

        # Set x-axis labels
        labels = {}
        (0...num_small_buckets).each do |i|
          time_sec = i * small_bucket_size
          labels[i] = "#{time_sec}s" if time_sec % @x_axis_label_interval == 0
        end

        # Generate main graph (requests)
        graph = Gruff::Line.new(1400)
        graph.title = @graph_title
        graph.x_axis_label = "Time (10-second intervals)"
        graph.y_axis_label = "Requests per Interval"
        graph.hide_dots = false
        graph.line_width = 3
        graph.labels = labels

        graph.data("Success", bucketed_data.map { |d| d[:success] })
        graph.data("Rejected", bucketed_data.map { |d| d[:circuit_open] })
        graph.data("Error", bucketed_data.map { |d| d[:error] })

        graph.write(@graph_filename)
        puts "Graph saved to #{@graph_filename}"

        # Generate duration graph
        duration_graph = Gruff::Line.new(1400)
        duration_graph.title = "#{@graph_title} - Total Request Duration"
        duration_graph.x_axis_label = "Time (10-second intervals)"
        duration_graph.y_axis_label = "Total Request Duration (seconds)"
        duration_graph.hide_dots = false
        duration_graph.line_width = 3
        duration_graph.labels = labels

        duration_graph.data("Total Request Duration", bucketed_data.map { |d| d[:sum_request_duration] })

        duration_filename = @graph_filename.sub(%r{([^/]+)$}, 'duration-\1')
        duration_graph.write(duration_filename)
        puts "Duration graph saved to #{duration_filename}"
      end
    end
  end
end
