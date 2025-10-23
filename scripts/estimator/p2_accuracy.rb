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
  QUANTILE = 0.5 # Median (P50)

  def run
    puts "P² Estimator Convergence Visualization"
    puts "=" * 80
    puts "Generating #{TOTAL_OBSERVATIONS} observations from Normal(100, 15)"
    puts "Tracking median estimate every #{SAMPLE_INTERVAL} observations"
    puts "=" * 80
    puts

    normal_distribution = Rubystats::NormalDistribution.new(100, 15)
    all_values = Array.new(TOTAL_OBSERVATIONS) { normal_distribution.rng }

    observation_counts = []
    p2_estimates = []
    exact_medians = []

    estimator = Semian::P2QuantileEstimator.new(QUANTILE)

    all_values.each_with_index do |value, idx|
      estimator.add_observation(value)

      next unless (idx + 1) % SAMPLE_INTERVAL == 0 || idx == TOTAL_OBSERVATIONS - 1

      n = idx + 1
      observation_counts << n

      # Get P2 estimate
      p2_estimates << estimator.estimate

      # Calculate exact median from observations so far
      exact_medians << calculate_exact_median(all_values[0..idx])

      if n % 1000 == 0
        print("\rProcessed: #{n}/#{TOTAL_OBSERVATIONS}")
      end
    end

    puts "\r" + " " * 50

    # Print final results
    final_mse = (p2_estimates.last - exact_medians.last)**2
    puts "\nFinal Results (#{TOTAL_OBSERVATIONS} observations):"
    puts "  P² Estimate:  #{format("%.4f", p2_estimates.last)}"
    puts "  Exact Median: #{format("%.4f", exact_medians.last)}"
    puts "  MSE:          #{format("%.6f", final_mse)}"
    puts "  Theoretical:  ~100.0 (μ for Normal(100, 15))"
    puts

    # Create visualization
    output_dir = File.dirname(__FILE__)
    create_convergence_plot(observation_counts, p2_estimates, exact_medians, output_dir)
    create_error_plot(observation_counts, p2_estimates, exact_medians, output_dir)

    puts "=" * 80
    puts "Visualizations saved to: #{output_dir}"
    puts "  - p2_convergence.png (Estimates over time)"
    puts "  - p2_mse_over_time.png (MSE over time)"
    puts "=" * 80
  end

  private

  def calculate_exact_median(values)
    sorted = values.sort
    n = sorted.length
    if n.odd?
      sorted[n / 2]
    else
      (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    end
  end

  def create_convergence_plot(observation_counts, p2_estimates, exact_medians, output_dir)
    g = Gruff::Line.new(1400)
    g.title = "P² Estimator Convergence: Median Estimate vs Actual"
    g.x_axis_label = "Number of Observations"
    g.y_axis_label = "Median Estimate"
    g.hide_dots = true
    g.theme = {
      colors: ["#4ecdc4", "#ff6b6b", "#95e1d3"],
      marker_color: "#aaa",
      font_color: "#333",
      background_colors: ["#fff", "#f8f9fa"],
    }

    # Add data series
    g.data("P² Estimate", p2_estimates)
    g.data("Exact Median", exact_medians)

    # Add theoretical line (μ = 100)
    theoretical_line = Array.new(observation_counts.length, 100.0)
    g.data("Theoretical (μ=100)", theoretical_line)

    all_values = p2_estimates + exact_medians
    min_val = all_values.min
    max_val = all_values.max
    margin = (max_val - min_val) * 0.1 # Add 10% margin
    g.minimum_value = [min_val - margin, 95].max # Don't go below 95
    g.maximum_value = [max_val + margin, 105].min # Don't go above 105

    labels = {}
    observation_counts.each_with_index do |count, idx|
      if count % 1000 == 0 || idx == 0 || idx == observation_counts.length - 1
        labels[idx] = "#{count / 1000}k"
      end
    end
    g.labels = labels

    output_path = File.join(output_dir, "p2_convergence.png")
    g.write(output_path)
    puts "\nGenerated: p2_convergence.png"
  end

  def create_error_plot(observation_counts, p2_estimates, exact_medians, output_dir)
    mse_values = p2_estimates.zip(exact_medians).map { |p2, exact| (p2 - exact)**2 }

    g = Gruff::Line.new(1400)
    g.title = "P² Estimator: Mean Squared Error Over Time"
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

    output_path = File.join(output_dir, "p2_mse_over_time.png")
    g.write(output_path)
    puts "Generated: p2_mse_over_time.png"
  end
end

if __FILE__ == $PROGRAM_NAME
  demo = P2AccuracyBenchmark.new
  demo.run
end
