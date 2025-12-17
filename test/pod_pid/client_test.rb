# frozen_string_literal: true

require "rubygems"
require "bundler/setup"
require "minitest/autorun"
require "forwardable"
require "async"
require "async/bus"

require_relative "../../lib/semian/pod_pid"

module Semian
  module PodPID
    class ClientTest < Minitest::Test
      def setup
        @client = Client.new
      end

      def test_should_reject_returns_false_when_rate_is_zero
        refute(@client.should_reject?("mysql"))
      end

      def test_should_reject_respects_cached_rate
        @client.update_rejection_rate("mysql", 1.0)

        assert(@client.should_reject?("mysql"))
      end

      def test_rejection_rate_returns_zero_for_unknown_resource
        assert_equal(0.0, @client.rejection_rate("unknown"))
      end

      def test_update_rejection_rate_updates_cache
        @client.update_rejection_rate("mysql", 0.5)

        assert_equal(0.5, @client.rejection_rate("mysql"))
      end

      def test_record_observation_returns_false_when_not_connected
        refute(@client.record_observation("mysql", :success))
      end

      def test_multiple_resources_have_independent_rates
        @client.update_rejection_rate("mysql", 0.3)
        @client.update_rejection_rate("redis", 0.7)

        assert_equal(0.3, @client.rejection_rate("mysql"))
        assert_equal(0.7, @client.rejection_rate("redis"))
      end

      def test_metrics_returns_nil_when_not_connected
        assert_nil(@client.metrics("mysql"))
      end
    end
  end
end
