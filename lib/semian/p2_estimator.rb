# frozen_string_literal: true

# The P^2 quantile estimator
# https://dl.acm.org/doi/pdf/10.1145/4372.4378
# https://aakinshin.net/posts/p2-quantile-estimator-intro/
# https://aakinshin.net/posts/p2-quantile-estimator-rounding-issue/ (addreses rounding error in original paper)

# Problem statement: How do we estimate quantiles for a stream of data in O(1) space
# P^2 (Piecewise-Parabolic) quantile estimator is a sequential estimator
# Standard approaches to calculating quantiles involve storing observations, sorting them, and then selecting the desired percentile
# This is not efficent for large streams of data, in the case of Semian this estimator will be called on a hot-path so we need to be efficient
# Instead, this algorithm only sorts a fixed number of marker heights and uses a piecewise parabolic function to estimate the quantile
# This allows us to estimate the quantile in O(1) space and O(1) time

# At a high level, the algorithm works as follows:
# Start with 5 marker heights and 5 positions
# The marker heights are the values of the quantiles we are estimating
# The positions are the positions of the marker heights in the sorted list of observations
# As we get new observations, we update the marker heights and positions
# We use a piecewise parabolic function to estimate the quantile (depending on our condition, we use either a parabolic or linear function)

module Semian
  # P^2 quantile estimator - used for P90 error-rate estimation
  class P2QuantileEstimator
    def initialize(quantile = 0.9)
      @quantile = quantile.to_f
      @actual_marker_positions = (0...5).to_a
      @desired_marker_positions = (0...5).map(&:to_f)
      @marker_heights = (0...5).map(&:to_f)
      @count = 0
    end

    def estimate
      raise "Sequence contains no elements" if @count == 0

      if @count <= 5
        sorted_marker_heights = @marker_heights[0...@count].sort
        index = ((@count - 1) * @quantile).round
        return sorted_marker_heights[index]
      end

      @marker_heights[2]
    end

    def reset
      @count = 0
      @actual_marker_positions = (0...5).to_a
      @desired_marker_positions = (0...5).map(&:to_f)
      @marker_heights = (0...5).map(&:to_f)
    end

    def state
      {
        observations: @count,
        markers: @marker_heights.dup,
        positions: @actual_marker_positions.dup,
        quantile: @quantile,
      }
    end

    def add_observation(value)
      if @count < 5
        @marker_heights[@count] = value
        @count += 1
        if @count == 5
          @marker_heights.sort!
          (0...5).each { |i| @actual_marker_positions[i] = i }

          @desired_marker_positions[0] = 0
          @desired_marker_positions[1] = 2 * @quantile
          @desired_marker_positions[2] = 4 * @quantile
          @desired_marker_positions[3] = 2 + 2 * @quantile
          @desired_marker_positions[4] = 4
        end
        return
      end

      @marker_interval_index = 0
      if value < @marker_heights[0]
        @marker_heights[0] = value
        @marker_interval_index = 0
      elsif value < @marker_heights[1]
        @marker_interval_index = 1
      elsif value < @marker_heights[2]
        @marker_interval_index = 2
      elsif value < @marker_heights[3]
        @marker_interval_index = 3
      else
        @marker_heights[4] = value
        @marker_interval_index = 3
      end

      ((@marker_interval_index + 1)...5).each { |i| @actual_marker_positions[i] += 1 }

      @desired_marker_positions[1] = @count * @quantile / 2
      @desired_marker_positions[2] = @count * @quantile
      @desired_marker_positions[3] = @count * ((1 + @quantile) / 2)
      @desired_marker_positions[4] = @count

      (1..3).each do |i|
        @position_difference = @desired_marker_positions[i] - @actual_marker_positions[i]
        next unless @position_difference >= 1 && @actual_marker_positions[i + 1] - @actual_marker_positions[i] > 1 || @position_difference <= -1 && @actual_marker_positions[i - 1] - @actual_marker_positions[i] < -1 # rubocop:disable Style

        @adjustment_direction = @position_difference <=> 0
        @parabolic_estimate = parabolic(i, @adjustment_direction)
        @marker_heights[i] = if @marker_heights[i - 1] < @parabolic_estimate && @parabolic_estimate < @marker_heights[i + 1]
          @parabolic_estimate
        else
          linear(i, @adjustment_direction)
        end
        @actual_marker_positions[i] += @adjustment_direction
      end
      @count += 1
    end

    private

    def parabolic(i, d)
      @marker_heights[i] + d / (@actual_marker_positions[i + 1] - @actual_marker_positions[i - 1]) * (
        (@actual_marker_positions[i] - @actual_marker_positions[i - 1] + d) * (@marker_heights[i + 1] - @marker_heights[i]) / (@actual_marker_positions[i + 1] - @actual_marker_positions[i]) +
        (@actual_marker_positions[i + 1] - @actual_marker_positions[i] - d) * (@marker_heights[i] - @marker_heights[i - 1]) / (@actual_marker_positions[i] - @actual_marker_positions[i - 1])
      )
    end

    def linear(i, d)
      @marker_heights[i] + d * (@marker_heights[i + d] - @marker_heights[i]) / (@actual_marker_positions[i + d] - @actual_marker_positions[i])
    end
  end
end
