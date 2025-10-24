#!/usr/bin/env ruby
# frozen_string_literal: true

# Visualize P2 quantile estimator convergence to actual median over time

require "benchmark"

begin
  require "gruff"
  require "rubystats"
rescue LoadError => e
  puts "Error: Required gem is not installed."
  puts "Please install with: gem install gruff rubystats"
  puts "Error details: #{e.message}"
  exit(1)
end

require_relative "../../lib/semian/p2_estimator"

class P2AccuracyBenchmark
  TOTAL_OBSERVATIONS = 10_000
  SAMPLE_INTERVAL = 100 # Track estimate every N observations
  QUANTILES = [0.5, 0.9] # P50 (Median) and P90

  def run
    puts "P² Estimator Convergence Visualization"
    puts "=" * 80
    puts "Generating #{TOTAL_OBSERVATIONS} observations from Normal(100, 15)"
    puts "Tracking quantile estimates (P50, P90) every #{SAMPLE_INTERVAL} observations"
    puts "=" * 80
    puts

    # Generate all observations once
    normal_distribution = Rubystats::NormalDistribution.new(100, 15)
    all_values = Array.new(TOTAL_OBSERVATIONS) { normal_distribution.rng }

    output_dir = File.dirname(__FILE__)

    # Run benchmark for each quantile
    QUANTILES.each do |quantile|
      run_quantile_benchmark(quantile, all_values, output_dir)
    end

    puts "=" * 80
    puts "All visualizations saved to: #{output_dir}"
    QUANTILES.each do |q|
      quantile_label = "p#{(q * 100).to_i}"
      puts "  - #{quantile_label}_convergence.png"
      puts "  - #{quantile_label}_mse_over_time.png"
    end
    puts "=" * 80
  end

  private

  def run_quantile_benchmark(quantile, all_values, output_dir)
    quantile_label = "P#{(quantile * 100).to_i}"
    puts "\nProcessing #{quantile_label}..."
    puts "-" * 80

    observation_counts = []
    p2_estimates = []
    exact_quantiles = []

    estimator = Semian::P2QuantileEstimator.new(quantile)

    all_values.each_with_index do |value, idx|
      estimator.add_observation(value)

      next unless (idx + 1) % SAMPLE_INTERVAL == 0 || idx == TOTAL_OBSERVATIONS - 1

      n = idx + 1
      observation_counts << n

      # Get P2 estimate
      p2_estimates << estimator.estimate

      # Calculate exact quantile from observations so far
      exact_quantiles << calculate_exact_quantile(all_values[0..idx], quantile)

      if n % 1000 == 0
        print("\rProcessed: #{n}/#{TOTAL_OBSERVATIONS}")
      end
    end

    puts "\r" + " " * 50

    # Print final results
    final_mse = (p2_estimates.last - exact_quantiles.last)**2
    puts "\nFinal Results for #{quantile_label} (#{TOTAL_OBSERVATIONS} observations):"
    puts "  P² Estimate:     #{format("%.4f", p2_estimates.last)}"
    puts "  Exact #{quantile_label}:       #{format("%.4f", exact_quantiles.last)}"
    puts "  MSE:             #{format("%.6f", final_mse)}"
    puts

    # Create visualization
    create_convergence_plot(observation_counts, p2_estimates, exact_quantiles, quantile, output_dir)
    create_error_plot(observation_counts, p2_estimates, exact_quantiles, quantile, output_dir)
  end

  def calculate_exact_quantile(values, quantile)
    sorted = values.sort
    n = sorted.length

    # Linear interpolation between closest ranks
    index = quantile * (n - 1)
    lower = index.floor
    upper = index.ceil

    if lower == upper
      sorted[lower]
    else
      # Interpolate between the two values
      weight = index - lower
      sorted[lower] * (1 - weight) + sorted[upper] * weight
    end
  end

  def create_convergence_plot(observation_counts, p2_estimates, exact_quantiles, quantile, output_dir)
    quantile_label = "P#{(quantile * 100).to_i}"
    quantile_filename = "p#{(quantile * 100).to_i}"

    g = Gruff::Line.new(1400)
    g.title = "P² Estimator Convergence: #{quantile_label} Estimate vs Actual"
    g.x_axis_label = "Number of Observations"
    g.y_axis_label = "#{quantile_label} Estimate"
    g.hide_dots = true
    g.theme = {
      colors: ["#4ecdc4", "#ff6b6b", "#95e1d3"],
      marker_color: "#aaa",
      font_color: "#333",
      background_colors: ["#fff", "#f8f9fa"],
    }

    # Add data series
    g.data("P² Estimate", p2_estimates)
    g.data("Exact #{quantile_label}", exact_quantiles)

    # Add theoretical line for P50 only (μ = 100 for median)
    if quantile == 0.5
      theoretical_line = Array.new(observation_counts.length, 100.0)
      g.data("Theoretical (μ=100)", theoretical_line)
    end

    all_values = p2_estimates + exact_quantiles
    min_val = all_values.min
    max_val = all_values.max
    margin = (max_val - min_val) * 0.1 # Add 10% margin
    g.minimum_value = min_val - margin
    g.maximum_value = max_val + margin

    labels = {}
    observation_counts.each_with_index do |count, idx|
      if count % 1000 == 0 || idx == 0 || idx == observation_counts.length - 1
        labels[idx] = "#{count / 1000}k"
      end
    end
    g.labels = labels

    output_path = File.join(output_dir, "#{quantile_filename}_convergence.png")
    g.write(output_path)
    puts "\nGenerated: #{quantile_filename}_convergence.png"
  end

  def create_error_plot(observation_counts, p2_estimates, exact_quantiles, quantile, output_dir)
    quantile_label = "P#{(quantile * 100).to_i}"
    quantile_filename = "p#{(quantile * 100).to_i}"

    mse_values = p2_estimates.zip(exact_quantiles).map { |p2, exact| (p2 - exact)**2 }

    g = Gruff::Line.new(1400)
    g.title = "P² Estimator (#{quantile_label}): Mean Squared Error Over Time"
    g.x_axis_label = "Number of Observations"
    g.y_axis_label = "MSE (P² - Exact)²"
    g.hide_dots = true
    g.theme = {
      colors: ["#667eea"],
      marker_color: "#aaa",
      font_color: "#333",
      background_colors: ["#fff", "#f8f9fa"],
    }

    g.data("Mean Squared Error", mse_values)

    labels = {}
    observation_counts.each_with_index do |count, idx|
      if count % 1000 == 0 || idx == 0 || idx == observation_counts.length - 1
        labels[idx] = "#{count / 1000}k"
      end
    end
    g.labels = labels

    output_path = File.join(output_dir, "#{quantile_filename}_mse_over_time.png")
    g.write(output_path)
    puts "Generated: #{quantile_filename}_mse_over_time.png"
  end
end

if __FILE__ == $PROGRAM_NAME
  demo = P2AccuracyBenchmark.new
  demo.run
end
