#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to collect baseline data by running all experiments multiple times
# Usage: ruby collect_baseline_data.rb <num_runs>
# Example: ruby collect_baseline_data.rb 5

require_relative "regression_config"
require "fileutils"

def discover_experiment_csvs
  # Find all time_analysis CSV files in results/csv/
  csv_files = Dir.glob(File.join(File.dirname(__FILE__), RegressionConfig::CSV_PATH, "*_time_analysis.csv"))

  if csv_files.empty?
    puts "❌ No CSV files found in #{RegressionConfig::CSV_PATH}"
    return {}
  end

  # Map CSV files to their corresponding experiment names
  experiment_mapping = {}
  csv_files.each do |csv_file|
    # Example: gradual_increase_adaptive_time_analysis.csv → gradual_increase_adaptive
    experiment_name = File.basename(csv_file, "_time_analysis.csv")
    experiment_mapping[experiment_name] = csv_file
  end

  experiment_mapping
end

def run_all_experiments?
  puts "Running all experiments (~15 minutes)..."
  puts "-" * 50

  result = system("cd #{File.dirname(__FILE__)} && ruby run_all_experiments.rb")

  puts "-" * 50
  if result
    puts "✅ All experiments completed successfully"
    true
  else
    puts "❌ Some experiments failed (check output above)"
    false
  end
end

def copy_all_csvs_to_baseline(run_number)
  experiment_mapping = discover_experiment_csvs

  if experiment_mapping.empty?
    puts "❌ No experiment CSV files found to copy"
    return 0
  end

  successful_copies = 0

  experiment_mapping.each do |experiment_name, csv_file|
    success = copy_csv_to_baseline(experiment_name, csv_file, run_number)
    successful_copies += 1 if success
  end

  puts "Copied #{successful_copies}/#{experiment_mapping.size} CSV files to baseline directories"
  successful_copies
end

def copy_csv_to_baseline(experiment_name, source_csv_path, run_number)
  unless File.exist?(source_csv_path)
    puts "❌ CSV file not found: #{source_csv_path}"
    return false
  end

  # Destination baseline directory - folder name matches experiment name
  baseline_dir = File.join(File.dirname(__FILE__), RegressionConfig::BASELINE_PATH, experiment_name)

  unless Dir.exist?(baseline_dir)
    FileUtils.mkdir_p(baseline_dir)
    puts "Created baseline directory: #{experiment_name}/"
  end

  # Destination file with run number prefix: run_001, run_002, etc.
  run_filename = "run_%03d_time_analysis.csv" % run_number
  destination_csv = File.join(baseline_dir, run_filename)

  FileUtils.cp(source_csv_path, destination_csv)
  puts "✅ #{File.basename(source_csv_path)} → baseline/#{experiment_name}/#{run_filename}"

  true
end

def collect_baseline_data?(num_runs)
  puts "🎯 Collecting baseline data using run_all_experiments.rb"
  puts "📊 Running all experiments #{num_runs} times"
  puts "⏰ Estimated time: ~#{num_runs * 15} minutes"
  puts "=" * 60

  successful_runs = 0
  total_experiments_copied = 0

  (1..num_runs).each do |run_number|
    puts "\n🔄 Run #{run_number}/#{num_runs}"
    puts "-" * 40

    if run_all_experiments?
      experiments_copied = copy_all_csvs_to_baseline(run_number)

      if experiments_copied > 0
        successful_runs += 1
        total_experiments_copied += experiments_copied
      end
    end
  end

  puts "\nCompleted #{successful_runs}/#{num_runs} runs (#{total_experiments_copied} files)"

  if successful_runs > 0
    puts "\n Baseline data collection completed!"
    puts "Next steps: compute_baselines.rb, detect_regressions.rb"
    true
  else
    puts "\n No runs completed successfully"
    false
  end
end

def main
  if ARGV.length != 1
    puts "Usage: ruby collect_baseline_data.rb <num_runs>"
    puts "Example: ruby collect_baseline_data.rb 5"
    exit(1)
  end

  num_runs = ARGV[0].to_i

  if num_runs <= 0
    puts "❌ Number of runs must be a positive integer"
    exit(1)
  end

  if num_runs < RegressionConfig::MIN_BASELINE_RUNS
    puts "⚠️  Warning: #{num_runs} runs is less than minimum recommended (#{RegressionConfig::MIN_BASELINE_RUNS})"
    puts "Consider running with at least #{RegressionConfig::MIN_BASELINE_RUNS} runs for stable baselines."
    puts ""
  end

  puts "🚀 Starting baseline data collection..."

  success = collect_baseline_data?(num_runs)

  exit(success ? 0 : 1)
end

main if __FILE__ == $0
