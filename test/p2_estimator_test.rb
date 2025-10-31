# frozen_string_literal: true

require "test_helper"

begin
  require "rubystats"
rescue LoadError
  puts "Warning: rubystats gem not installed. Install with: gem install rubystats"
end

class TestP2Estimator < Minitest::Test
  # Test median (P50) estimation on 1000 samples from Normal(0,1)
  def test_median_normal_distribution
    skip("rubystats gem not available") unless defined?(Rubystats)

    run_distribution_test(
      distribution: Rubystats::NormalDistribution.new(0, 1),
      distribution_name: "Normal(0,1)",
      probability: 0.5,
      n: 1000,
      seed: 42,
      theoretical_quantile: 0.0, # Standard normal median = 0
      max_acceptable_mse: 0.01,
      max_delta_from_exact: 0.1,
    )
  end

  # Test median (P50) estimation on 1000 samples from Beta(10,2)
  def test_median_beta_distribution
    skip("rubystats gem not available") unless defined?(Rubystats)

    # For Beta(α,β), median ≈ (α-1/3)/(α+β-2/3) when α,β > 1
    # Beta(10,2): median ≈ (10-1/3)/(10+2-2/3) ≈ 9.667/11.333 ≈ 0.853
    run_distribution_test(
      distribution: Rubystats::BetaDistribution.new(10, 2),
      distribution_name: "Beta(10,2)",
      probability: 0.5,
      n: 1000,
      seed: 42,
      theoretical_quantile: 0.853, # Approximate median for Beta(10,2)
      max_acceptable_mse: 0.005, # Beta is bounded [0,1], so tighter tolerance
      max_delta_from_exact: 0.05,
    )
  end

  # Test median (P50) estimation on 1000 samples from Exponential(1)
  def test_median_exponential_distribution
    skip("rubystats gem not available") unless defined?(Rubystats)

    # For Exponential(λ), the median is ln(2)/λ
    # For λ=1: median = ln(2) ≈ 0.693147
    run_distribution_test(
      distribution: Rubystats::ExponentialDistribution.new(1),
      distribution_name: "Exponential(1)",
      probability: 0.5,
      n: 1000,
      seed: 42,
      theoretical_quantile: Math.log(2), # ln(2) ≈ 0.693147
      max_acceptable_mse: 0.01,
      max_delta_from_exact: 0.1,
    )
  end

  private

  # Run a distribution test
  def run_distribution_test(
    distribution:,
    distribution_name:,
    probability:,
    n:,
    seed:,
    theoretical_quantile:,
    max_acceptable_mse:,
    max_delta_from_exact:
  )
    # Set seed for reproducibility
    srand(seed)

    # Generate samples using rubystats
    samples = Array.new(n) { distribution.rng }

    # Estimate quantile using P2 estimator
    estimator = Semian::P2QuantileEstimator.new(probability)
    samples.each { |value| estimator.add_observation(value) }
    estimate = estimator.estimate

    # Calculate exact quantile from the actual samples
    exact_quantile = calculate_exact_quantile(samples.sort, probability)

    # Calculate MSE against exact quantile
    mse_exact = (estimate - exact_quantile)**2

    # Quantile label for output
    quantile_label = probability == 0.5 ? "Median" : "P#{(probability * 100).to_i}"

    # Output for visibility
    puts "\n--- #{quantile_label} Estimation Results (N=#{n}, #{distribution_name}) ---"
    if theoretical_quantile
      puts "Theoretical #{quantile_label}: #{format("%.6f", theoretical_quantile)}"
    end
    puts "Exact #{quantile_label}:       #{format("%.6f", exact_quantile)}"
    puts "P2 Estimate:            #{format("%.6f", estimate)}"
    puts "MSE (vs exact):         #{format("%.8f", mse_exact)}"
    puts "Error (vs exact):       #{format("%.6f", (estimate - exact_quantile).abs)}"

    # Test against theoretical quantile if provided
    if theoretical_quantile
      mse_theoretical = (estimate - theoretical_quantile)**2
      puts "MSE (vs theory):        #{format("%.8f", mse_theoretical)}"
      puts "Error (vs theory):      #{format("%.6f", (estimate - theoretical_quantile).abs)}"

      assert_operator(
        mse_theoretical,
        :<,
        max_acceptable_mse,
        "#{distribution_name}: #{quantile_label} estimate MSE from theoretical value should be < #{max_acceptable_mse}. " \
          "Got MSE=#{format("%.8f", mse_theoretical)}, " \
          "Estimate=#{format("%.6f", estimate)}, " \
          "Theoretical=#{format("%.6f", theoretical_quantile)}, " \
          "Error=#{format("%.6f", (estimate - theoretical_quantile).abs)}",
      )
    end

    # Always test against exact quantile from sample
    assert_in_delta(
      exact_quantile,
      estimate,
      max_delta_from_exact,
      "#{distribution_name}: #{quantile_label} estimate should be close to exact sample quantile. " \
        "Estimate=#{format("%.6f", estimate)}, " \
        "Exact=#{format("%.6f", exact_quantile)}, " \
        "Delta=#{format("%.6f", (estimate - exact_quantile).abs)}",
    )

    # MSE against exact should also be reasonable
    assert_operator(
      mse_exact,
      :<,
      max_acceptable_mse,
      "#{distribution_name}: MSE against exact quantile should be < #{max_acceptable_mse}. " \
        "Got MSE=#{format("%.8f", mse_exact)}",
    )
  end

  # Calculate exact quantile using linear interpolation
  def calculate_exact_quantile(sorted_data, probability)
    index = (sorted_data.length - 1) * probability

    if index == index.to_i
      sorted_data[index.to_i]
    else
      lower = sorted_data[index.floor]
      upper = sorted_data[index.ceil]
      lower + (index - index.floor) * (upper - lower)
    end
  end
end
