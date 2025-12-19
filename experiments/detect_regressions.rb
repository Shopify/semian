#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "regression_config"

def load_baseline(experiment_name)
  baseline_file = File.join(RegressionConfig::BASELINE_PATH, experiment_name, "computed_baseline.txt")

  unless File.exist?(baseline_file)
    return
  end

  baseline = {}
  File.readlines(baseline_file).each do |line|
    next if line.start_with?("#") || line.strip.empty?

    key, value = line.strip.split("=")
    baseline[key] = value.to_f
  end

  baseline
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

def count_violations(values, lower_bound, upper_bound)
  violations = values.count { |v| v < lower_bound || v > upper_bound }
  total = values.length

  return 0.0 if total == 0

  violations.to_f / total.to_f
end

def detect_regression(experiment_name, csv_path)
  baseline = load_baseline(experiment_name)

  unless baseline
    return {
      experiment: experiment_name,
      status: "SKIP",
      reason: "No baseline found. Run compute_baselines.rb first.",
    }
  end

  metrics = parse_csv_and_extract_metrics(csv_path)

  if metrics[:deviations].empty?
    return {
      experiment: experiment_name,
      status: "ERROR",
      reason: "Could not parse CSV data",
    }
  end

  # Check violations for each metric
  deviation_violation_rate = count_violations(
    metrics[:deviations],
    baseline["deviation_p#{RegressionConfig::LOWER_PERCENTILE}"],
    baseline["deviation_p#{RegressionConfig::UPPER_PERCENTILE}"],
  )

  error_rate_violation_rate = count_violations(
    metrics[:error_rates],
    baseline["error_rate_p#{RegressionConfig::LOWER_PERCENTILE}"],
    baseline["error_rate_p#{RegressionConfig::UPPER_PERCENTILE}"],
  )

  rejection_rate_violation_rate = count_violations(
    metrics[:rejection_rates],
    baseline["rejection_rate_p#{RegressionConfig::LOWER_PERCENTILE}"],
    baseline["rejection_rate_p#{RegressionConfig::UPPER_PERCENTILE}"],
  )

  # Determine overall status
  violations = []

  if deviation_violation_rate > RegressionConfig::DEVIATION_VIOLATION_THRESHOLD
    violations << "deviation (#{(deviation_violation_rate * 100).round(1)}% > #{RegressionConfig::DEVIATION_VIOLATION_THRESHOLD * 100}%)"
  end

  if error_rate_violation_rate > RegressionConfig::ERROR_RATE_VIOLATION_THRESHOLD
    violations << "error_rate (#{(error_rate_violation_rate * 100).round(1)}% > #{RegressionConfig::ERROR_RATE_VIOLATION_THRESHOLD * 100}%)"
  end

  if rejection_rate_violation_rate > RegressionConfig::REJECTION_RATE_VIOLATION_THRESHOLD
    violations << "rejection_rate (#{(rejection_rate_violation_rate * 100).round(1)}% > #{RegressionConfig::REJECTION_RATE_VIOLATION_THRESHOLD * 100}%)"
  end

  if violations.empty?
    status = "PASS"
    reason = "All metrics within expected bounds"
  else
    status = "FAIL"
    reason = "Violations: #{violations.join(", ")}"
  end

  {
    experiment: experiment_name,
    status: status,
    reason: reason,
    details: {
      deviation_violation_rate: (deviation_violation_rate * 100).round(1),
      error_rate_violation_rate: (error_rate_violation_rate * 100).round(1),
      rejection_rate_violation_rate: (rejection_rate_violation_rate * 100).round(1),
    },
  }
end

def detect_all_regressions
  csv_files = Dir.glob("#{RegressionConfig::CSV_PATH}/*_time_analysis.csv")

  if csv_files.empty?
    puts "❌ No experiment CSV files found in #{RegressionConfig::CSV_PATH}"
    puts "Run some experiments first."
    return
  end

  puts "🔍 Checking for regressions in #{csv_files.length} experiments..."
  puts

  results = []

  csv_files.each do |csv_file|
    experiment_name = File.basename(csv_file, "_time_analysis.csv")
    result = detect_regression(experiment_name, csv_file)
    results << result

    case result[:status]
    when "PASS"
      puts "✅ #{experiment_name}: #{result[:reason]}"
    when "FAIL"
      puts "❌ #{experiment_name}: #{result[:reason]}"
    when "SKIP"
      puts "⚠️  #{experiment_name}: #{result[:reason]}"
    when "ERROR"
      puts "💥 #{experiment_name}: #{result[:reason]}"
    end

    if result[:details]
      puts "   Violation rates: Dev #{result[:details][:deviation_violation_rate]}%, Err #{result[:details][:error_rate_violation_rate]}%, Rej #{result[:details][:rejection_rate_violation_rate]}%"
    end

    puts
  end

  # Summary
  passed = results.count { |r| r[:status] == "PASS" }
  failed = results.count { |r| r[:status] == "FAIL" }
  skipped = results.count { |r| r[:status] == "SKIP" }
  errors = results.count { |r| r[:status] == "ERROR" }

  puts "=" * 60
  puts "🎯 REGRESSION DETECTION SUMMARY"
  puts "   ✅ Passed: #{passed}"
  puts "   ❌ Failed: #{failed}"
  puts "   ⚠️  Skipped: #{skipped}"
  puts "   💥 Errors: #{errors}"

  if failed > 0
    puts "\n🚨 POTENTIAL REGRESSIONS DETECTED!"
    puts "Review failed experiments before merging PR."
    exit(1)
  else
    puts "\n🎉 All experiments within expected bounds!"
    exit(0)
  end
end

detect_all_regressions if __FILE__ == $0
