# frozen_string_literal: true

# Configuration for regression detection - easily tunable thresholds
module RegressionConfig
  # Percentile bounds for control limits
  LOWER_PERCENTILE = 3
  UPPER_PERCENTILE = 97

  # Violation thresholds
  DEVIATION_VIOLATION_THRESHOLD = 0.3
  ERROR_RATE_VIOLATION_THRESHOLD = 0.3
  REJECTION_RATE_VIOLATION_THRESHOLD = 0.3

  MIN_BASELINE_RUNS = 10

  # Paths
  BASELINE_PATH = "results/baseline"
  CSV_PATH = "results/csv"
end
