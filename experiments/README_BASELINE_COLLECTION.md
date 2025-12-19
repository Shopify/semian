# Automated Baseline Collection Script

## Overview

Detailed guide for the `collect_baseline_data.rb` script - automates gathering baseline data for regression detection by running all experiments multiple times and organizing the results.

📋 **For the complete regression detection system**: See [`REGRESSION_DETECTION.md`](REGRESSION_DETECTION.md)

## Usage

### Simple Usage
```bash
# Run all experiments 5 times (minimum recommended)
ruby collect_baseline_data.rb 5

# Run all experiments 10 times (better for stable baselines)
ruby collect_baseline_data.rb 10

# Run all experiments 10 times (most stable baselines)
ruby collect_baseline_data.rb 15
```


## What It Does

1. **Runs all experiments at once** using `run_all_experiments.rb` (already optimized with threading)
2. **Copies all generated CSV files** to their respective baseline directories
3. **Names files systematically**: `run_001_time_analysis.csv`, `run_002_time_analysis.csv`, etc.
4. **Repeats the process N times** (where N is your parameter)
5. **Leaves original CSV files unchanged** in `results/csv/` directory

## Example Output

```bash
$ ruby collect_baseline_data.rb 3

🚀 Starting baseline data collection...
🎯 Using run_all_experiments.rb (much simpler and faster!)

🎯 Collecting baseline data using run_all_experiments.rb
📊 Running all experiments 3 times
⏰ Estimated time: ~45 minutes (assuming ~15 min per run)
============================================================

🔄 Run 1/3
----------------------------------------
   🧪 Running all experiments...
   ✅ All experiments completed successfully
   📋 Copied 18/18 CSV files to baseline directories
   ✅ Run 1: 18 experiments copied to baselines

🔄 Run 2/3
----------------------------------------
   🧪 Running all experiments...
   ✅ All experiments completed successfully
   📋 Copied 18/18 CSV files to baseline directories
   ✅ Run 2: 18 experiments copied to baselines

🔄 Run 3/3
----------------------------------------
   🧪 Running all experiments...
   ✅ All experiments completed successfully
   📋 Copied 18/18 CSV files to baseline directories
   ✅ Run 3: 18 experiments copied to baselines

============================================================
📈 BASELINE COLLECTION SUMMARY
   ✅ Successful runs: 3/3
   📊 Total experiment files copied: 54

🎉 Baseline data collection completed!
📋 Next steps:
   1. Run: ruby compute_baselines.rb
   2. Run: ruby detect_regressions.rb
```

## File Organization

After running, your structure will look like:

```
experiments/
└── results/
    ├── csv/                                    # Original files (unchanged)
    │   ├── gradual_increase_adaptive_time_analysis.csv
    │   ├── gradual_increase_time_analysis.csv
    │   ├── sudden_error_spike_100_adaptive_time_analysis.csv
    │   └── [other experiments]_time_analysis.csv
    └── baseline/                              # Organized baseline data
        ├── gradual_increase_adaptive/         # Folder name matches CSV name
        │   ├── run_001_time_analysis.csv     # Run 1
        │   ├── run_002_time_analysis.csv     # Run 2
        │   ├── run_003_time_analysis.csv     # Run 3
        │   └── computed_baseline.txt         # (after compute_baselines.rb)
        ├── gradual_increase/                  # Non-adaptive version
        │   ├── run_001_time_analysis.csv
        │   ├── run_002_time_analysis.csv
        │   └── run_003_time_analysis.csv
        ├── sudden_error_spike_100_adaptive/
        │   ├── run_001_time_analysis.csv
        │   ├── run_002_time_analysis.csv
        │   └── run_003_time_analysis.csv
        └── [other experiments]/
```

## Next Steps

After collecting baseline data:

1. **Compute baselines**: `ruby compute_baselines.rb`
2. **See full system documentation**: [`REGRESSION_DETECTION.md`](REGRESSION_DETECTION.md)

**💡 Much faster and simpler!** Uses the existing `run_all_experiments.rb` which already handles parallel execution efficiently.

## Error Handling

The script will:
- ✅ Continue if individual experiment runs fail
- ✅ Report partial success (e.g., 4/5 runs successful)
- ✅ Create baseline directories automatically
- ✅ Skip copying CSV if experiment failed
- ❌ Exit with error code if no experiments succeeded

## Tips

1. **Run during off-hours** - Experiments are resource-intensive
2. **Start small** - Try 5 runs first, then increase if needed
3. **Monitor progress** - Each experiment takes ~15 minutes
4. **Stable baselines** - More runs = more stable percentile calculations
5. **One-time setup** - You only need to run this when initially setting up or updating baselines

## Troubleshooting

**"No experiment files found"**
- Make sure you're running from the `experiments/` directory
- Verify experiment files exist: `ls experiments/experiment_*_adaptive.rb`

**Experiments failing**
- Check individual experiment files can run: `ruby experiments/experiment_gradual_increase_adaptive.rb`
- Ensure dependencies are installed
- Check system resources (CPU/memory)

**CSV files not found**
- Verify experiments are generating `*_time_analysis.csv` files in `results/csv/`
- Check experiment output for errors
