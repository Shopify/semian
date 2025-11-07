#!/usr/bin/env ruby
# frozen_string_literal: true

require "thread"

# Get all experiment files (excluding the windup experiment)
# TODO: Include lower bound windup experiment once we have a way to make it run in a reasonable time.
experiment_files = Dir.glob("experiments/*.rb").reject { |file| file.include?("experiment_lower_bound_windup_adaptive.rb") }.sort

puts "Found #{experiment_files.length} experiment files to run:"
experiment_files.each { |file| puts "  - #{file}" }
puts "\nRunning all experiments in parallel..."
puts "=" * 60

# Track results
results = {}
mutex = Mutex.new

# Create threads for each experiment file
threads = experiment_files.map do |experiment_file|
  Thread.new do
    start_time = Time.now

    # Capture output and error
    output = nil
    error = nil
    exit_status = nil

    begin
      # Run the experiment file and capture output
      output = %x(bundle exec ruby #{experiment_file} 2>&1)
      exit_status = $?.exitstatus
    rescue => e
      error = e.message
      exit_status = 1
    end

    end_time = Time.now
    duration = end_time - start_time

    # Thread-safe result storage
    mutex.synchronize do
      results[experiment_file] = {
        output: output,
        error: error,
        exit_status: exit_status,
        duration: duration,
      }

      status = exit_status == 0 ? "✅ SUCCESS" : "❌ FAILED"
      puts "[#{Time.now.strftime("%H:%M:%S")}] #{status} #{experiment_file} (#{duration.round(2)}s)"
    end
  end
end

# Wait for all threads to complete
threads.each(&:join)

puts "\n" + "=" * 60
puts "All experiments completed!"
puts "=" * 60

# Summary
total_duration = results.values.map { |r| r[:duration] }.sum
successful = results.select { |_, r| r[:exit_status] == 0 }
failed = results.select { |_, r| r[:exit_status] != 0 }

puts "\nSUMMARY:"
puts "  Total files: #{results.length}"
puts "  Successful: #{successful.length}"
puts "  Failed: #{failed.length}"
puts "  Total execution time: #{total_duration.round(2)}s"

# Show failed experiments with details
if failed.any?
  puts "\nFAILED EXPERIMENTS:"
  failed.each do |file, result|
    puts "\n#{file}:"
    puts "  Exit status: #{result[:exit_status]}"
    puts "  Duration: #{result[:duration].round(2)}s"
    if result[:error]
      puts "  Error: #{result[:error]}"
    end
    if result[:output] && !result[:output].strip.empty?
      puts "  Output:"
      result[:output].split("\n").each { |line| puts "    #{line}" }
    end
  end
end

exit failed.any? ? 1 : 0
