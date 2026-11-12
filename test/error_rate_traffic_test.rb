# frozen_string_literal: true

require "test_helper"

class TestErrorRateTraffic < Minitest::Test
  BackendError = Class.new(StandardError)

  def setup
    @previous_logger = Semian.logger
    Semian.logger = Logger.new(nil)
  end

  def teardown
    Semian.unsubscribe(:error_rate_traffic)
    Semian.destroy_all_resources
    Semian.logger = @previous_logger
  end

  # Poisson arrivals only support statistical expectations: these are single fixed-seed runs, not guarantees.
  def test_partial_failures_do_not_open_the_rate_breaker_in_a_fixed_seed_poisson_run
    [5, 100].each do |rate|
      result = simulate(rate: rate, failure_rate: 0.083)
      classic = simulate(rate: rate, failure_rate: 0.083, classic: true)

      assert_empty(result[:opens])
      assert_in_delta(result[:backend_failure_rate], result[:caller_failure_rate], 0.01)
      assert_operator(classic[:caller_failure_rate], :>, rate == 5 ? 0.25 : 0.75)
    end

    assert_empty(simulate(rate: 20, failure_rate: 0.25)[:opens])
  end

  def test_total_outage_opens_in_a_fixed_seed_poisson_run
    [5, 20, 100].each do |rate|
      result = simulate(rate: rate, failure_rate: 1.0, duration: 80, outage_at: 60)

      refute_empty(result[:opens])
    end
  end

  # With evenly spaced requests the window holds a known mix, so the detection delay is bounded.
  def test_total_outage_with_periodic_traffic_opens_within_threshold_times_window_plus_a_bucket
    [5, 20, 100].each do |rate|
      result = simulate(rate: rate, failure_rate: 1.0, duration: 80, outage_at: 60, periodic: true)

      refute_empty(result[:opens])
      assert_operator(result[:opens].first - 60, :<=, 0.5 * 10 + 1)
    end
  end

  # Periodic, because 1 request/s on average can still burst past the minimum volume.
  def test_periodic_traffic_below_the_minimum_volume_never_opens
    result = simulate(rate: 1, failure_rate: 1.0, periodic: true)

    assert_empty(result[:opens])
  end

  private

  def simulate(rate:, failure_rate:, classic: false, duration: 600, outage_at: nil, periodic: false)
    now = 0.0
    real_clock = Process.method(:clock_gettime)
    clock = ->(clock_id, *args) { clock_id == Process::CLOCK_MONOTONIC ? now : real_clock.call(clock_id, *args) }
    result = nil
    Process.stub(:clock_gettime, clock) do
      options = if classic
        { error_threshold: 6, error_threshold_timeout: 35 }
      else
        { error_rate_threshold: 0.5, minimum_request_volume: 20, error_rate_window: 10 }
      end
      resource = Semian.register(
        :traffic,
        bulkhead: false,
        exceptions: [BackendError],
        error_timeout: 5,
        success_threshold: 2,
        **options,
      )
      opens = []
      Semian.subscribe(:error_rate_traffic) do |event, _, _, _, payload|
        opens << now if event == :state_change && payload[:state] == :open
      end
      random = Random.new(42)
      attempts = failures = backend_calls = backend_failures = 0
      loop do
        now += periodic ? 1.0 / rate : -Math.log(1.0 - random.rand) / rate
        break if now >= duration

        attempts += 1
        begin
          resource.acquire do
            backend_calls += 1
            if random.rand < (outage_at && now < outage_at ? 0 : failure_rate)
              backend_failures += 1
              raise BackendError
            end
          end
        rescue BackendError, Semian::OpenCircuitError
          failures += 1
        end
      end
      result = {
        opens: opens,
        backend_failure_rate: backend_failures.fdiv(backend_calls),
        caller_failure_rate: failures.fdiv(attempts),
      }
      Semian.unsubscribe(:error_rate_traffic)
      Semian.destroy(:traffic)
    end
    result
  end
end
