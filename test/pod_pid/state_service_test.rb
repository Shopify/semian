# frozen_string_literal: true

require "rubygems"
require "bundler/setup"
require "minitest/autorun"
require "tempfile"
require "forwardable"

require_relative "../../lib/semian/pod_pid/state_service"

module Semian
  module PodPID
    class StateServiceTest < Minitest::Test
      def setup
        @temp_file = Tempfile.new("semian_state_service_test")
        @wal_path = @temp_file.path
        @temp_file.close
        File.delete(@wal_path) if File.exist?(@wal_path)

        @service = StateService.new(
          kp: 1.0,
          ki: 0.2,
          kd: 0.0,
          window_size: 10,
          sliding_interval: 1,
          initial_error_rate: 0.05,
          wal_path: @wal_path,
        )
      end

      def teardown
        @service.stop
        File.delete(@wal_path) if File.exist?(@wal_path)
        @temp_file&.unlink
      end

      def test_record_observation_creates_resource
        @service.record_observation("mysql", :success)

        assert(@service.resources.key?("mysql"))
      end

      def test_record_observation_tracks_outcomes
        5.times { @service.record_observation("mysql", :success) }
        3.times { @service.record_observation("mysql", :error) }
        2.times { @service.record_observation("mysql", :rejected) }

        metrics = @service.metrics("mysql")

        assert_equal(5, metrics[:current_window_requests][:success])
        assert_equal(3, metrics[:current_window_requests][:error])
        assert_equal(2, metrics[:current_window_requests][:rejected])
      end

      def test_rejection_rate_returns_zero_for_unknown_resource
        assert_equal(0.0, @service.rejection_rate("unknown"))
      end

      def test_update_all_resources_computes_rejection_rate
        10.times { @service.record_observation("mysql", :error) }
        @service.update_all_resources

        assert_operator(@service.rejection_rate("mysql"), :>, 0.0)
      end

      def test_wal_persists_on_rejection_rate_change
        10.times { @service.record_observation("mysql", :error) }
        @service.update_all_resources

        assert_operator(File.size(@wal_path), :>, 0)
      end

      def test_restores_state_from_wal
        10.times { @service.record_observation("mysql", :error) }
        @service.update_all_resources
        old_rate = @service.rejection_rate("mysql")

        new_service = StateService.new(
          kp: 1.0,
          ki: 0.2,
          kd: 0.0,
          window_size: 10,
          sliding_interval: 1,
          initial_error_rate: 0.05,
          wal_path: @wal_path,
        )

        assert_equal(old_rate, new_service.rejection_rate("mysql"))
      end

      def test_on_rejection_rate_change_callback
        updates = []
        @service.on_rejection_rate_change = ->(resource, rate) { updates << [resource, rate] }

        10.times { @service.record_observation("mysql", :error) }
        @service.update_all_resources

        assert_equal(1, updates.size)
        assert_equal("mysql", updates[0][0])
        assert_operator(updates[0][1], :>, 0.0)
      end
    end
  end
end
