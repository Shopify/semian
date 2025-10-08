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
# TODO: Add a high level description of the algorithm

module Semian
  # P^2 quantile estimator - used for P90 error-rate estimation
  class P2QuantileEstimator
    def initialize(quantile = 0.9)
      @quantile = quantile.to_f
      @n = (0...5).to_a
      @ns = (0...5).map(&:to_f)
      @q = (0...5).map(&:to_f)
      @count = 0
    end

    def estimate
      raise "Sequence contains no elements" if @count == 0

      if @count <= 5
        sorted_q = @q[0...@count].sort
        index = ((@count - 1) * @quantile).round
        return sorted_q[index]
      end

      @q[2]
    end

    def reset
      @count = 0
      @n = (0...5).to_a
      @ns = (0...5).map(&:to_f)
      @q = (0...5).map(&:to_f)
    end

    def state
      {
        observations: @count,
        markers: @q.dup,
        positions: @n.dup,
        quantile: @quantile,
      }
    end

    def add_observation(value)
      if @count < 5
        @q[@count] = value
        @count += 1
        if @count == 5
          @q.sort!
          (0...5).each { |i| @n[i] = i }

          @ns[0] = 0
          @ns[1] = 2 * @quantile
          @ns[2] = 4 * @quantile
          @ns[3] = 2 + 2 * @quantile
          @ns[4] = 4
        end
        return
      end

      @k = 0
      if value < @q[0]
        @q[0] = value
        @k = 0
      elsif value < @q[1]
        @k = 1
      elsif value < @q[2]
        @k = 2
      elsif value < @q[3]
        @k = 3
      else
        @q[4] = value
        @k = 3
      end

      ((@k + 1)...5).each { |i| @n[i] += 1 }

      @ns[1] = @count * @quantile / 2
      @ns[2] = @count * @quantile
      @ns[3] = @count * ((1 + @quantile) / 2)
      @ns[4] = @count

      (1..3).each do |i|
        @d = @ns[i] - @n[i]
        next unless @d >= 1 && @n[i + 1] - @n[i] > 1 || @d <= -1 && @n[i - 1] - @n[i] < -1 # rubocop:disable Style

        @d_int = @d <=> 0
        @qs = parabolic(i, @d_int)
        @q[i] = if @q[i - 1] < @qs && @qs < @q[i + 1]
          @qs
        else
          linear(i, @d_int)
        end
        @n[i] += @d_int
      end
      @count += 1
    end

    private

    def parabolic(i, d)
      @q[i] + d / (@n[i + 1] - @n[i - 1]) * (
        (@n[i] - @n[i - 1] + d) * (@q[i + 1] - @q[i]) / (@n[i + 1] - @n[i]) +
        (@n[i + 1] - @n[i] - d) * (@q[i] - @q[i - 1]) / (@n[i] - @n[i - 1])
      )
    end

    def linear(i, d)
      @q[i] + d * (@q[i + d] - @q[i]) / (@n[i + d] - @n[i])
    end
  end
end
