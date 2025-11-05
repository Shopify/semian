# frozen_string_literal: true

module Semian
  module Experiments
    # Test runner for circuit breaker experiments (both adaptive and classic)
    # Handles all the common logic: service creation, threading, monitoring, analysis, and visualization
    class DegradationPhase
      attr_reader :healthy, :error_rate, :latency

      def initialize(healthy: nil, error_rate: nil, latency: nil)
        @healthy = healthy
        @error_rate = error_rate
        @latency = latency
      end
    end

    class CircuitBreakerTestRunner
      attr_reader :test_name, :resource_name, :degradation_phases, :phase_duration, :graph_title, :graph_filename, :service_count, :target_service

      def initialize(
        test_name:,
        resource_name:,
        degradation_phases:,
        phase_duration:,
        graph_title:,
        semian_config:,
        graph_filename: nil,
        num_threads: 60,
        requests_per_second_per_thread: 50,
        x_axis_label_interval: nil,
        service_count: 1,
        graph_bucket_size: nil,
        base_error_rate: nil
      )
        @test_name = test_name
        @resource_name = resource_name
        @degradation_phases = degradation_phases
        @phase_duration = phase_duration
        @graph_title = graph_title
        @semian_config = semian_config
        @is_adaptive = semian_config[:adaptive_circuit_breaker] == true
        @graph_filename = graph_filename || "#{resource_name}.png"
        @num_threads = num_threads
        @requests_per_second_per_thread = requests_per_second_per_thread
        @x_axis_label_interval = x_axis_label_interval || phase_duration
        @test_duration = degradation_phases.length * phase_duration
        @service_count = service_count
        @target_service = nil
        @graph_bucket_size = graph_bucket_size || (@is_adaptive ? 10 : 1)
        @base_error_rate = if base_error_rate.nil?
          @is_adaptive ? 0.01 : 0.0
        else
          base_error_rate
        end
      end

      def run
        setup_services
        setup_resources
        start_threads
        execute_phases
        wait_for_completion
        generate_analysis
        generate_visualization
      end

      private

      def setup_services
        puts "Creating mock service..."
        @services = []
        @service_count.times do
          @services << MockService.new(
            endpoints_count: 50,
            min_latency: 0.01,
            max_latency: 0.3,
            distribution: {
              type: :log_normal,
              mean: 0.15,
              std_dev: 0.05,
            },
            error_rate: @base_error_rate,
            timeout: 5,
          )
        end
        # We always assume that you want to degrade one service, and we pick @services[0]
        # If you have more complex experiments with multi-service degradation,
        # feel free to change this code.
        @target_service = @services[0]
      end

      def setup_resources
        puts "Initializing Semian resource..."
        begin
          @services.each do |service|
            init_resource = ExperimentalResource.new(
              name: "#{@resource_name}_#{service.object_id}",
              service: service,
              semian: @semian_config,
            )
            init_resource.request(0)
          end
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
        @state_transitions = []
        @state_transitions_mutex = Mutex.new

        start_request_threads
        subscribe_to_metrics if @is_adaptive
        subscribe_to_state_changes unless @is_adaptive
      end

      def start_request_threads
        total_rps = @num_threads * @requests_per_second_per_thread
        puts "Starting #{@num_threads} concurrent request threads (#{@requests_per_second_per_thread} requests/second each = #{total_rps} rps total)..."
        puts "Each thread will have its own adapter instance connected to the shared service...\n"

        @request_threads = []
        @num_threads.times do |thread_num|
          @request_threads << Thread.new do
            thread_id = Thread.current.object_id
            @thread_timings[thread_id] = { samples: [] }

            sleep_interval = 1.0 / @requests_per_second_per_thread
            until @done
              sleep(sleep_interval)
              service = @services.sample
              # technically, we are creating a new resource instance on every request.
              # But the resource class is pretty much only a wrapper around things that are longer-living.
              # So this works just fine.
              thread_resource = ExperimentalResource.new(
                name: "#{@resource_name}_#{service.object_id}_thread_#{thread_num}",
                service: service,
                semian: @semian_config,
              )

              request_start = Time.now
              begin
                thread_resource.request(rand(service.endpoints_count))

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
                @thread_timings[thread_id][:samples] << { duration: request_duration, timestamp: timestamp }
              end
            end
          end
        end
      end

      def subscribe_to_metrics
        target_resource_prefix = "#{@resource_name}_#{@target_service.object_id}_thread_"
        # Track metrics per window to aggregate across threads
        @window_metrics = {}

        @subscription = Semian.subscribe do |event, resource, _scope, _adapter, payload|
          # Only capture adaptive_update events for our target service thread resources
          next unless event == :adaptive_update && resource.name.to_s.start_with?(target_resource_prefix)

          total_request_time = @thread_timings.values.sum { |t| t[:samples].sum { |s| s[:duration] } }

          @pid_mutex.synchronize do
            timestamp = Time.now.to_i
            window_key = payload[:window_number] || timestamp

            # Initialize window metrics if this is the first thread reporting for this window
            @window_metrics[window_key] ||= {
              timestamp: timestamp,
              window: nil,
              error_rates: [],
              ideal_error_rate: payload[:ideal_error_rate],
              p_values: [],
              previous_p_values: [],
              rejection_rates: [],
              integrals: [],
              derivatives: [],
              total_request_time: total_request_time,
            }

            # Accumulate metrics from each thread
            @window_metrics[window_key][:error_rates] << payload[:error_rate]
            @window_metrics[window_key][:p_values] << payload[:p_value]
            @window_metrics[window_key][:previous_p_values] << payload[:previous_p_value]
            @window_metrics[window_key][:rejection_rates] << payload[:rejection_rate]
            @window_metrics[window_key][:integrals] << payload[:integral]
            @window_metrics[window_key][:derivatives] << payload[:derivative]

            # When we've collected metrics from all threads, create the aggregated snapshot
            if @window_metrics[window_key][:error_rates].length == @num_threads
              metrics = @window_metrics[window_key]

              @pid_snapshots << {
                timestamp: metrics[:timestamp],
                window: @pid_snapshots.length + 1,
                error_rate_avg: metrics[:error_rates].sum / metrics[:error_rates].length.to_f,
                error_rate_min: metrics[:error_rates].min,
                error_rate_max: metrics[:error_rates].max,
                ideal_error_rate: metrics[:ideal_error_rate],
                rejection_rate_avg: metrics[:rejection_rates].sum / metrics[:rejection_rates].length.to_f,
                rejection_rate_min: metrics[:rejection_rates].min,
                rejection_rate_max: metrics[:rejection_rates].max,
                integral_avg: metrics[:integrals].sum / metrics[:integrals].length.to_f,
                integral_min: metrics[:integrals].min,
                integral_max: metrics[:integrals].max,
                derivative_avg: metrics[:derivatives].sum / metrics[:derivatives].length.to_f,
                derivative_min: metrics[:derivatives].min,
                derivative_max: metrics[:derivatives].max,
                total_request_time: metrics[:total_request_time],
              }

              # Clean up processed window
              @window_metrics.delete(window_key)
            end
          end
        end
      end

      def subscribe_to_state_changes
        target_resource_prefix = "#{@resource_name}_#{@target_service.object_id}_thread_"

        @subscription = Semian.subscribe do |event, resource, _scope, _adapter, payload|
          # Only capture state_change events for our target service thread resources
          next unless event == :state_change && resource.name.to_s.start_with?(target_resource_prefix)

          @state_transitions_mutex.synchronize do
            @state_transitions << {
              timestamp: Time.now.to_i,
              state: payload[:state],
              resource_name: resource.name,
            }
          end
        end
      end

      def execute_phases
        puts "\n=== #{@test_name} (ADAPTIVE) ==="
        puts "Error rate: #{@degradation_phases.map { |r| r.error_rate ? "#{(r.error_rate * 100).round(1)}%" : "N/A" }.join(" -> ")}"
        puts "Latency: #{@degradation_phases.map { |r| r.latency ? "#{(r.latency * 1000).round(1)}ms" : "N/A" }.join(" -> ")}"
        puts "Phase duration: #{@phase_duration} seconds (#{(@phase_duration / 60.0).round(1)} minutes) per phase"
        puts "Duration: #{@test_duration} seconds (#{(@test_duration / 60.0).round(1)} minutes)"
        puts "Starting test...\n"

        @start_time = Time.now

        @degradation_phases.each_with_index do |degradation_phase, idx|
          if idx > 0
            if degradation_phase.healthy
              puts "\n=== Transitioning to healthy state ==="
              @target_service.reset_degradation
            else
              if degradation_phase.error_rate
                puts "\n=== Transitioning to #{(degradation_phase.error_rate * 100).round(1)}% error rate ==="
                @target_service.set_error_rate(degradation_phase.error_rate)
              end
              if degradation_phase.latency
                puts "\n=== Transitioning to #{(degradation_phase.latency * 1000).round(1)}ms latency ==="
                @target_service.add_latency(degradation_phase.latency)
              end
            end
          end

          sleep(@phase_duration)
        end
      end

      def wait_for_completion
        @done = true
        puts "\nWaiting for all request threads to finish..."
        @request_threads.each(&:join)

        Semian.unsubscribe(@subscription) if @is_adaptive

        @end_time = Time.now

        # Clean up per-thread resources
        @services.each do |service|
          @num_threads.times do |thread_num|
            resource_name = "#{@resource_name}_#{service.object_id}_thread_#{thread_num}".to_sym
            Semian.destroy(resource_name)
          end
        end
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

          degradation_phase = @degradation_phases[bucket_idx] || @degradation_phases.last
          phase_error_rate = degradation_phase.error_rate || @base_error_rate
          phase_label = "[Target: #{(phase_error_rate * 100).round(1)}%]"

          puts "#{status} #{bucket_time_range} #{phase_label}: #{bucket_total} requests | Success: #{bucket_success} | Errors: #{bucket_errors} (#{error_pct}%) | Rejected: #{bucket_circuit} (#{circuit_pct}%)"
        end
      end

      def display_thread_timing_statistics
        return if @thread_timings.empty?

        puts "\n=== Thread Timing Statistics ==="

        total_times = @thread_timings.values.map { |t| t[:samples].sum { |s| s[:duration] } }
        request_counts = @thread_timings.values.map { |t| t[:samples].size }

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

        puts "\n=== PID Controller State Per Window (Aggregated across #{@num_threads} threads) ==="
        puts format("%-8s %-20s %-15s %-20s %-20s %-20s %-15s", "Window", "Err % (min-max)", "Ideal Err %", "Reject % (min-max)", "Integral (min-max)", "Derivative (min-max)", "Total Req Time")
        puts "-" * 140

        @pid_snapshots.each do |snapshot|
          error_rate_str = format_metric_range(snapshot[:error_rate_avg], snapshot[:error_rate_min], snapshot[:error_rate_max], is_percent: true)
          reject_rate_str = format_metric_range(snapshot[:rejection_rate_avg], snapshot[:rejection_rate_min], snapshot[:rejection_rate_max], is_percent: true)
          integral_str = format_metric_range(snapshot[:integral_avg], snapshot[:integral_min], snapshot[:integral_max])
          derivative_str = format_metric_range(snapshot[:derivative_avg], snapshot[:derivative_min], snapshot[:derivative_max])

          puts format(
            "%-8d %-20s %-15s %-20s %-20s %-20s %-15s",
            snapshot[:window],
            error_rate_str,
            "#{(snapshot[:ideal_error_rate] * 100).round(2)}%",
            reject_rate_str,
            integral_str,
            derivative_str,
            "#{(snapshot[:total_request_time] || 0).round(2)}s",
          )
        end

        puts "\n📊 Key Observations:"
        puts "  - Windows captured: #{@pid_snapshots.length}"
        puts "  - Max avg rejection rate: #{(@pid_snapshots.map { |s| s[:rejection_rate_avg] }.max * 100).round(2)}%"
        puts "  - Avg integral range: #{@pid_snapshots.map { |s| s[:integral_avg] }.min.round(4)} to #{@pid_snapshots.map { |s| s[:integral_avg] }.max.round(4)}"
      end

      def format_metric_range(avg, min, max, is_percent: false)
        if is_percent
          avg_str = "#{(avg * 100).round(2)}%"
          min_str = "#{(min * 100).round(2)}%"
          max_str = "#{(max * 100).round(2)}%"
        else
          avg_str = avg.round(4).to_s
          min_str = min.round(4).to_s
          max_str = max.round(4).to_s
        end
        "#{avg_str} (#{min_str}-#{max_str})"
      end

      def generate_visualization
        puts "\nGenerating visualization..."
        require "gruff"

        # Aggregate data into buckets for detailed visualization
        bucket_size = @graph_bucket_size
        num_buckets = (@test_duration / bucket_size.to_f).ceil

        bucketed_data = []
        (0...num_buckets).each do |bucket_idx|
          bucket_start = @outcomes.keys[0] + (bucket_idx * bucket_size)
          bucket_end = bucket_start + bucket_size
          bucket_data = @outcomes.select { |time, _| time >= bucket_start && time < bucket_end }

          bucket_samples = []
          @thread_timings.each_value do |thread_data|
            bucket_samples.concat(thread_data[:samples].select { |s| s[:timestamp] >= bucket_start && s[:timestamp] < bucket_end })
          end

          sum_request_duration = bucket_samples.sum { |s| s[:duration] }
          throughput = bucket_samples.size

          bucketed_data << {
            success: bucket_data.values.sum { |d| d[:success] },
            circuit_open: bucket_data.values.sum { |d| d[:circuit_open] },
            error: bucket_data.values.sum { |d| d[:error] },
            sum_request_duration: sum_request_duration,
            throughput: throughput,
          }
        end

        # Set x-axis labels
        labels = {}
        (0...num_buckets).each do |i|
          time_sec = i * bucket_size
          labels[i] = "#{time_sec}s" if time_sec % @x_axis_label_interval == 0
        end

        # Create two graphs: one for requests per interval that shows success and failure rates, and a separate graph for total request duration.
        # They're separate graphs because the difference in scale of the two values prevents the request duration signal from being clearly visible on the same graph.

        # Generate main graph (requests)
        graph = Gruff::Line.new(1400)
        graph.title = @graph_title
        graph.x_axis_label = "Time (#{bucket_size}-second intervals)"
        graph.y_axis_label = "Requests per Interval"
        graph.hide_dots = false
        graph.line_width = 3
        graph.labels = labels

        graph.data("Success", bucketed_data.map { |d| d[:success] })
        graph.data("Rejected", bucketed_data.map { |d| d[:circuit_open] })
        graph.data("Error", bucketed_data.map { |d| d[:error] })

        # Add circuit state transition markers (for classic CB)
        unless @is_adaptive
          add_state_transition_markers(graph, bucketed_data, bucket_size, num_buckets)
        end

        graph.write(@graph_filename)
        puts "Graph saved to #{@graph_filename}"

        # Generate duration graph
        duration_graph = Gruff::Line.new(1400)
        duration_graph.title = "#{@graph_title} - Total Request Duration"
        duration_graph.x_axis_label = "Time (#{bucket_size}-second intervals)"
        duration_graph.y_axis_label = "Total Request Duration (seconds)"
        duration_graph.hide_dots = false
        duration_graph.line_width = 3
        duration_graph.labels = labels

        duration_graph.data("Total Request Duration", bucketed_data.map { |d| d[:sum_request_duration] })

        duration_filename = @graph_filename.sub(%r{([^/]+)$}, 'duration-\1')
        duration_graph.write(duration_filename)
        puts "Duration graph saved to #{duration_filename}"

        # Generate throughput graph
        throughput_graph = Gruff::Line.new(1400)
        throughput_graph.title = "#{@graph_title} - Total Request Throughput"
        throughput_graph.x_axis_label = "Time (#{bucket_size}-second intervals)"
        throughput_graph.y_axis_label = "Total Request Throughput"
        throughput_graph.hide_dots = false
        throughput_graph.line_width = 3
        throughput_graph.labels = labels

        throughput_graph.data("Total Request Throughput", bucketed_data.map { |d| d[:throughput] })

        throughput_filename = @graph_filename.sub(%r{([^/]+)$}, 'throughput-\1')
        throughput_graph.write(throughput_filename)
        puts "Throughput graph saved to #{throughput_filename}"
      end

      def add_state_transition_markers(graph, bucketed_data, bucket_size, num_buckets)
        return if @state_transitions.empty?

        test_start = @outcomes.keys[0]

        @state_transitions.each_with_index do |transition, idx|
          # Calculate which bucket this transition falls into
          elapsed = transition[:timestamp] - test_start
          bucket_idx = (elapsed / bucket_size).to_i

          next if bucket_idx < 0 || bucket_idx >= num_buckets

          # Add vertical reference line at this bucket index
          color = case transition[:state]
          when :open then "red"
          when :half_open then "gray"
          when :closed then "green"
          end

          graph.reference_lines[:"transition_#{idx}"] = {
            index: bucket_idx,
            color: color,
            width: 2,
          }
        end
      end
    end
  end
end
