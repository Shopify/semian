# P² Quantile Estimator Scripts

This directory contains scripts for testing and visualizing the P² (P-squared) quantile estimator implementation.

## What is the P² Estimator?

The P² algorithm is a sequential quantile estimation algorithm that calculates quantiles (like median, p90, p95) in **O(1) constant memory** and **O(1) time per observation**. This is ideal for streaming data where you can't store all observations.

Traditional methods require sorting all data, which uses O(n) memory. The P² estimator only needs 5 markers regardless of data size.

**Reference Paper:**
> Jain, Raj, and Imrich Chlamtac. "The P² algorithm for dynamic calculation of quantiles and histograms without storing observations." *Communications of the ACM* 28, no. 10 (1985): 1076-1085.

## Scripts

### `p2_accuracy.rb`

Visualizes how the P² estimator converges to the true median over time.

**What it does:**
- Generates 10,000 observations from a Normal(100, 15) distribution
- Tracks both the P² estimate and exact median every 100 observations
- Creates two visualizations showing convergence and mean squared error (MSE)

**Prerequisites:**
```bash
gem install gruff rubystats
```

**Usage:**
```bash
ruby scripts/estimator/p2_accuracy.rb
```

**Output:**
- `p2_convergence.png` - Shows P² estimate vs exact median vs theoretical over time
- `p2_mse_over_time.png` - Shows mean squared error decreasing as sample size increases

**Example Output:**
```
P² Estimator Convergence Visualization
================================================================================
Generating 10000 observations from Normal(100, 15)
Tracking median estimate every 100 observations
================================================================================

Final Results (10000 observations):
  P² Estimate:  99.9442
  Exact Median: 99.9604
  MSE:          0.000262
  Theoretical:  ~100.0 (μ for Normal(100, 15))

================================================================================
Visualizations saved to: scripts/estimator
  - p2_convergence.png (Estimates over time)
  - p2_mse_over_time.png (MSE over time)
================================================================================
```

## Understanding the Visualizations

### Convergence Plot
Shows three lines:
- **P² Estimate** (teal): The running estimate from the P² algorithm
- **Exact Median** (red): The actual median calculated from all observations so far
- **Theoretical** (light teal): The true population median (μ=100)

As more observations are added, all three lines should converge together.

### MSE Plot
Shows how the mean squared error `(P² estimate - exact median)²` decreases over time. This demonstrates that the P² estimator becomes more accurate as it processes more data.

## Implementation

The P² estimator is implemented in `lib/semian/p2_estimator.rb` and is used by Semian's adaptive circuit breaker for real-time error rate estimation.

