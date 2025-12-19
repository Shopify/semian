#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "regression_config"

MID_PERCENTILE = RegressionConfig::LOWER_PERCENTILE + (RegressionConfig::UPPER_PERCENTILE - RegressionConfig::LOWER_PERCENTILE) / 2

def percentile(sorted_array, percent)
  return sorted_array.first if sorted_array.length == 1

  index = (percent / 100.0) * (sorted_array.length - 1)
  lower = sorted_array[index.floor]
  upper = sorted_array[index.ceil]

  lower + (upper - lower) * (index - index.floor)
end

def calculate_percentiles(values)
  return if values.empty?

  sorted = values.sort
  {
    "p#{RegressionConfig::LOWER_PERCENTILE}" => percentile(sorted, RegressionConfig::LOWER_PERCENTILE),
    "p#{MID_PERCENTILE}" => percentile(sorted, MID_PERCENTILE),
    "p#{RegressionConfig::UPPER_PERCENTILE}" => percentile(sorted, RegressionConfig::UPPER_PERCENTILE),
    "count" => sorted.length,
  }
end

def parse_csv_and_extract_metrics(csv_path)
  lines = File.readlines(csv_path)
  headers = lines[0].strip.split(",")

  # Find column indices
  error_idx = headers.index("Error %")
  rejected_idx = headers.index("Rejected %")
  target_idx = headers.index("Target Error Rate %")

  if error_idx.nil? || rejected_idx.nil? || target_idx.nil?
    puts "❌ Missing required columns in #{csv_path}"
    return { deviations: [], error_rates: [], rejection_rates: [] }
  end

  deviations = []
  error_rates = []
  rejection_rates = []

  lines[1..-1].each do |line|
    next if line.strip.empty?

    cols = line.strip.split(",")
    next if cols.length <= [error_idx, rejected_idx, target_idx].max

    error_rate = cols[error_idx].to_f
    rejection_rate = cols[rejected_idx].to_f
    target_rate = cols[target_idx].to_f

    actual = error_rate + rejection_rate

    deviation = if target_rate > 0
      ((actual - target_rate) / target_rate * 100).abs
    else
      actual > 0 ? 100.0 : 0.0
    end

    deviations << deviation
    error_rates << error_rate
    rejection_rates << rejection_rate
  end

  {
    deviations: deviations,
    error_rates: error_rates,
    rejection_rates: rejection_rates,
  }
end

def compute_baseline_for_experiment(experiment_name)
  baseline_dir = File.join(RegressionConfig::BASELINE_PATH, experiment_name)

  unless Dir.exist?(baseline_dir)
    puts "❌ Baseline directory not found: #{baseline_dir}"
    return false
  end

  csv_files = Dir.glob(File.join(baseline_dir, "*_time_analysis.csv"))

  if csv_files.length < RegressionConfig::MIN_BASELINE_RUNS
    puts "#{experiment_name}: Need #{RegressionConfig::MIN_BASELINE_RUNS}+ CSV files, found #{csv_files.length}"
    return false
  end
  all_deviations = []
  all_error_rates = []
  all_rejection_rates = []

  csv_files.each do |csv_file|
    data = parse_csv_and_extract_metrics(csv_file)
    all_deviations.concat(data[:deviations])
    all_error_rates.concat(data[:error_rates])
    all_rejection_rates.concat(data[:rejection_rates])
  end

  deviation_percentiles = calculate_percentiles(all_deviations)
  error_percentiles = calculate_percentiles(all_error_rates)
  rejection_percentiles = calculate_percentiles(all_rejection_rates)
  baseline_file = File.join(baseline_dir, "computed_baseline.txt")
  lower_key = "p#{RegressionConfig::LOWER_PERCENTILE}"
  mid_key = "p#{MID_PERCENTILE}"
  upper_key = "p#{RegressionConfig::UPPER_PERCENTILE}"

  File.open(baseline_file, "w") do |f|
    f.puts "# Baseline computed at #{Time.now}"
    f.puts "# Source files: #{csv_files.map { |x| File.basename(x) }.join(", ")}"
    f.puts "# Total data points: #{all_deviations.length}"
    f.puts
    f.puts "deviation_p#{RegressionConfig::LOWER_PERCENTILE}=#{deviation_percentiles[lower_key]}"
    f.puts "deviation_p#{MID_PERCENTILE}=#{deviation_percentiles[mid_key]}"
    f.puts "deviation_p#{RegressionConfig::UPPER_PERCENTILE}=#{deviation_percentiles[upper_key]}"
    f.puts
    f.puts "error_rate_p#{RegressionConfig::LOWER_PERCENTILE}=#{error_percentiles[lower_key]}"
    f.puts "error_rate_p#{MID_PERCENTILE}=#{error_percentiles[mid_key]}"
    f.puts "error_rate_p#{RegressionConfig::UPPER_PERCENTILE}=#{error_percentiles[upper_key]}"
    f.puts
    f.puts "rejection_rate_p#{RegressionConfig::LOWER_PERCENTILE}=#{rejection_percentiles[lower_key]}"
    f.puts "rejection_rate_p#{MID_PERCENTILE}=#{rejection_percentiles[mid_key]}"
    f.puts "rejection_rate_p#{RegressionConfig::UPPER_PERCENTILE}=#{rejection_percentiles[upper_key]}"
  end

  baseline = {
    deviation: deviation_percentiles,
    error_rate: error_percentiles,
    rejection_rate: rejection_percentiles,
  }

  lower_key = "p#{RegressionConfig::LOWER_PERCENTILE}"
  upper_key = "p#{RegressionConfig::UPPER_PERCENTILE}"

  puts "✅ #{experiment_name}: Baseline saved to #{File.basename(baseline_file)}"
  puts "   Deviation bounds: #{baseline[:deviation][lower_key].round(1)}% - #{baseline[:deviation][upper_key].round(1)}%"

  true
end

def compute_all_baselines
  experiment_dirs = Dir.glob(File.join(RegressionConfig::BASELINE_PATH, "*")).select { |f| File.directory?(f) }

  if experiment_dirs.empty?
    puts "❌ No baseline directories found. Run collect_baseline_data.rb first."
    return
  end

  puts "Computing baselines..."

  results = {}
  experiment_dirs.each do |dir|
    experiment_name = File.basename(dir)
    results[experiment_name] = compute_baseline_for_experiment(experiment_name)
    puts # blank line
  end

  successful = results.values.count(true)
  total = results.size

  puts "\nCompleted: #{successful}/#{total} successful"

  if successful < total
    failed = results.select { |_, success| !success }.keys
    puts "❌ Failed: #{failed.join(", ")}"
  else
    puts "Next steps: ruby detect_regressions.rb"
  end
end

compute_all_baselines if __FILE__ == $0
