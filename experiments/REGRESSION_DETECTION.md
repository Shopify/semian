# Circuit Breaker Regression Detection System

## Overview

Automated system to detect performance regressions in circuit breaker experiments using **percentile-based statistical control charts**. Eliminates manual visual comparison by providing boolean pass/fail decisions based on historical baseline data.

**🤖 Fully Automated**: Runs via GitHub Actions on every pull request - no manual intervention required.

## How It Works

1. **Baseline Collection**: Collect 5-10 historical "good" experiment runs for each experiment type
2. **Percentile Analysis**: Calculate 5th, 55th, and 95th percentiles for key metrics
3. **Control Limits**: Set bounds at 5th-95th percentile range (covers ~90% of historical variation)
4. **Violation Detection**: Flag experiment if >30% of time windows fall outside percentile bounds
5. **Multi-metric Evaluation**: Check deviation from target, error rates, and rejection rates
6. **Automated CI Integration**: GitHub Actions automatically runs full pipeline on every PR

## Quick Start

### 1. Collect Baseline Data

```bash
# Automated collection (recommended)
ruby collect_baseline_data.rb 5
```

📋 **For detailed instructions, examples, and troubleshooting**: See [`README_BASELINE_COLLECTION.md`](README_BASELINE_COLLECTION.md)

### 3. Compute Baselines
```bash
# Calculate percentiles from historical data
ruby compute_baselines.rb
```

### 4. Run Regression Detection
```bash
# Check current experiments against baselines
ruby detect_regressions.rb
```

### 5. CI Integration (Automated)
The GitHub Actions workflow automatically runs on every pull request:
```yaml
# .github/workflows/automated-experiment-result-checker.yml
- name: Run experiments and check for performance regressions
  run: |
    cd experiments
    bundle install
    bundle exec ruby run_all_experiments.rb
    ruby detect_regressions.rb
```

## Complete Workflow

### One-Time Setup
```bash
# Step 1: Collect baseline data - see README_BASELINE_COLLECTION.md for details
ruby collect_baseline_data.rb 15

# Step 2: Compute percentile baselines
ruby compute_baselines.rb
```

### Automated CI Usage
The regression detection runs automatically on every pull request via GitHub Actions:

1. **Automatic Trigger**: Runs on PR open, reopen, or new commits
2. **Full Pipeline**: Executes all experiments + regression detection
3. **Pass/Fail Results**: CI passes ✅ if no regressions, fails ❌ if regressions detected

**Manual Local Testing** (optional):
```bash
# Test locally before pushing
cd experiments
bundle install
bundle exec ruby run_all_experiments.rb
ruby detect_regressions.rb
```

## Configuration & Tuning

All thresholds are easily adjustable in `regression_config.rb`:

```ruby
module RegressionConfig
  # Percentile bounds for control limits
  LOWER_PERCENTILE = 5
  UPPER_PERCENTILE = 95

  # Violation thresholds (what % of time windows can violate bounds)
  DEVIATION_VIOLATION_THRESHOLD = 8
  ERROR_RATE_VIOLATION_THRESHOLD = 0.8
  REJECTION_RATE_VIOLATION_THRESHOLD = 0.8

  # Minimum baseline runs needed
  MIN_BASELINE_RUNS = 10
end
```

### Tuning Guidelines

**More Sensitive Detection** (catch smaller regressions):
- Tighten percentile bounds: `LOWER_PERCENTILE = 10`, `UPPER_PERCENTILE = 90`
- Lower violation thresholds: `DEVIATION_VIOLATION_THRESHOLD = 0.10` (10%)

**Less False Positives** (more tolerant of variation):
- Widen percentile bounds: `LOWER_PERCENTILE = 2`, `UPPER_PERCENTILE = 98`
- Raise violation thresholds: `DEVIATION_VIOLATION_THRESHOLD = 0.20` (20%)

**Different Experiments Need Different Sensitivity**:
- Modify per-experiment configs (future enhancement)
- For now, use conservative settings that work across all experiments

## File Structure

```
experiments/
├── regression_config.rb              # ✅ Tunable configuration
├── collect_baseline_data.rb          # ✅ Automated baseline data collection (creates directories automatically)
├── compute_baselines.rb              # ✅ Calculate percentiles from historical data
├── detect_regressions.rb             # ✅ Main regression detection
└── results/
    ├── baseline/                     # Historical "good" runs
    │   ├── gradual_increase_adaptive/
    │   │   ├── run_001_time_analysis.csv
    │   │   ├── run_002_time_analysis.csv
    │   │   ├── run_003_time_analysis.csv
    │   │   └── computed_baseline.txt  # Calculated percentiles
    │   └── [other experiment types]/
    └── csv/                          # Current experiment results
        ├── gradual_increase_adaptive_time_analysis.csv
        └── [other experiments]_time_analysis.csv
```

## Exit Codes

- **0**: All experiments passed (no regressions detected)
- **1**: Regressions detected

## Metrics Analyzed

For each 1-second time window:

1. **Deviation from Target** (Primary): `|actual_rate - target_rate| / target_rate * 100`
2. **Error Rate**: Raw error percentage
3. **Rejection Rate**: Raw rejection percentage

## Interpreting Results

### ✅ PASS Example
```
✅ gradual_increase_adaptive: All metrics within expected bounds
   Violation rates: Dev 5.2%, Err 3.1%, Rej 8.7%
```
All violation rates < 15% threshold.

### ❌ FAIL Example
```
❌ sudden_error_spike_100: Violations: deviation (23.5% > 15%)
   Violation rates: Dev 23.5%, Err 12.1%, Rej 14.2%
```
Deviation violation rate exceeded 15% threshold - potential regression detected.

### ⚠️ SKIP Example
```
⚠️ oscillating_errors: No baseline found. Run compute_baselines.rb first.
```
Need to establish baseline data for this experiment.

## Updating Baselines

When experiments legitimately improve (not regressions):

1. **Collect new baseline data**: `ruby collect_baseline_data.rb 15` (see [`README_BASELINE_COLLECTION.md`](README_BASELINE_COLLECTION.md))
2. **Recompute baselines**: `ruby compute_baselines.rb`
3. **Commit updated baseline files** to repository

## Troubleshooting

**"No baseline found"** - See [`README_BASELINE_COLLECTION.md`](README_BASELINE_COLLECTION.md) for detailed setup instructions

**Too many false positives** - System is too sensitive:
1. Increase violation thresholds in `regression_config.rb`
2. Widen percentile bounds (e.g., 2nd-98th percentile)
3. Collect more baseline data for stable percentiles

**Missing real regressions** - System not sensitive enough:
1. Decrease violation thresholds
2. Tighten percentile bounds (e.g., 10th-90th percentile)
3. Consider experiment-specific tuning

## Technical Details

**Why Percentiles vs Normal Distribution?**
- Circuit breaker data is **not normally distributed** (phase-based, bounded, heavy tails)
- Percentiles work with **any data distribution**
- More **robust to outliers** than mean ± standard deviation

**Why 5th-95th Percentiles?**
- Covers ~90% of historical variation
- Balances sensitivity vs false positive rate
- Industry standard for performance monitoring

**Why 15% Violation Threshold?**
- Allows some natural variation in experiment timing
- Based on analysis of your actual experiment data
- Configurable based on your tolerance for sensitivity

## Future Enhancements

- [ ] Per-experiment threshold configuration
- [ ] Trend detection (gradual drift over time)
