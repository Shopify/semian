# frozen_string_literal: true

module TimeHelper
  def time_travel(val)
    now_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    now_timestamp = Time.now

    new_monotonic = now_monotonic + val
    fake_stub_all_clock_gettime_behaviour
    Process.stubs(:clock_gettime).with(Process::CLOCK_MONOTONIC, anything).returns(new_monotonic)

    new_timestamp = now_timestamp + val
    Time.stubs(:now).returns(new_timestamp)

    yield
  ensure
    Time.unstub(:now)
    Process.unstub(:clock_gettime)
  end

  private

  def fake_stub_all_clock_gettime_behaviour
    # Only stub the monotonic clock, we don't want to override the behaviour of other clocks like the CPU time clock.
    # Unfortunately, Mocha does not provide a clean way to do this,
    # the only way I could come up with is this ugly implementation
    original_clock_gettime = Process.method(:clock_gettime)
    param1_options = [
      Process.const_defined?(:CLOCK_BOOTTIME) ? Process::CLOCK_BOOTTIME : nil,
      Process.const_defined?(:CLOCK_BOOTTIME_ALARM) ? Process::CLOCK_BOOTTIME_ALARM : nil,
      # Process::CLOCK_MONOTONIC, # we actually want to stub this one
      Process.const_defined?(:CLOCK_MONOTONIC_COARSE) ? Process::CLOCK_MONOTONIC_COARSE : nil,
      Process.const_defined?(:CLOCK_MONOTONIC_FAST) ? Process::CLOCK_MONOTONIC_FAST : nil,
      Process.const_defined?(:CLOCK_MONOTONIC_PRECISE) ? Process::CLOCK_MONOTONIC_PRECISE : nil,
      Process.const_defined?(:CLOCK_MONOTONIC_RAW) ? Process::CLOCK_MONOTONIC_RAW : nil,
      Process.const_defined?(:CLOCK_MONOTONIC_RAW_APPROX) ? Process::CLOCK_MONOTONIC_RAW_APPROX : nil,
      Process.const_defined?(:CLOCK_PROCESS_CPUTIME_ID) ? Process::CLOCK_PROCESS_CPUTIME_ID : nil,
      Process.const_defined?(:CLOCK_PROF) ? Process::CLOCK_PROF : nil,
      Process.const_defined?(:CLOCK_REALTIME) ? Process::CLOCK_REALTIME : nil,
      Process.const_defined?(:CLOCK_REALTIME_ALARM) ? Process::CLOCK_REALTIME_ALARM : nil,
      Process.const_defined?(:CLOCK_REALTIME_COARSE) ? Process::CLOCK_REALTIME_COARSE : nil,
      Process.const_defined?(:CLOCK_REALTIME_FAST) ? Process::CLOCK_REALTIME_FAST : nil,
      Process.const_defined?(:CLOCK_REALTIME_PRECISE) ? Process::CLOCK_REALTIME_PRECISE : nil,
      Process.const_defined?(:CLOCK_SECOND) ? Process::CLOCK_SECOND : nil,
      Process.const_defined?(:CLOCK_TAI) ? Process::CLOCK_TAI : nil,
      Process.const_defined?(:CLOCK_THREAD_CPUTIME_ID) ? Process::CLOCK_THREAD_CPUTIME_ID : nil,
      Process.const_defined?(:CLOCK_UPTIME) ? Process::CLOCK_UPTIME : nil,
      Process.const_defined?(:CLOCK_UPTIME_FAST) ? Process::CLOCK_UPTIME_FAST : nil,
      Process.const_defined?(:CLOCK_UPTIME_PRECISE) ? Process::CLOCK_UPTIME_PRECISE : nil,
      Process.const_defined?(:CLOCK_UPTIME_RAW) ? Process::CLOCK_UPTIME_RAW : nil,
      Process.const_defined?(:CLOCK_UPTIME_RAW_APPROX) ? Process::CLOCK_UPTIME_RAW_APPROX : nil,
      Process.const_defined?(:CLOCK_VIRTUAL) ? Process::CLOCK_VIRTUAL : nil,
    ].compact
    param2_options = [
      :float_microsecond,
      :float_millisecond,
      :float_second,
      :microsecond,
      :millisecond,
      :nanosecond,
      :second,
    ]

    param1_options.product(param2_options).each do |param1, param2|
      Process.stubs(:clock_gettime).with(param1, param2).returns(original_clock_gettime.call(param1, param2))
    end
  end
end
