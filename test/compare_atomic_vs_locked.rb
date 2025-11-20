# frozen_string_literal: true

# Quick benchmark to compare SharedMemory (atomic) vs SharedMemoryLocked (semaphore)
#
# Run in Docker:
#   bundle exec ruby -Ilib:test test/compare_atomic_vs_locked.rb

require "test_helper"

def benchmark_increments(shm, iterations:, label:)
  shm.write_int(0, 0)

  start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)

  iterations.times do
    shm.increment_int(0, 1)
  end

  finish = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
  elapsed_us = finish - start

  final_value = shm.read_int(0)

  puts "#{label}:"
  puts "  Iterations: #{iterations}"
  puts "  Final value: #{final_value}"
  puts "  Time: #{elapsed_us} μs (#{(elapsed_us / 1000.0).round(2)} ms)"
  puts "  Per operation: #{(elapsed_us.to_f / iterations).round(3)} μs"
  puts

  elapsed_us
end

unless Semian.sysv_semaphores_supported?
  puts "Skipping benchmark - SysV semaphores not supported on #{RUBY_PLATFORM}"
  puts "Run in Docker: docker exec -it semian bundle exec ruby -Ilib:test test/compare_atomic_vs_locked.rb"
  exit(0)
end

puts "=" * 80
puts "ATOMIC VS LOCKED BENCHMARK"
puts "=" * 80
puts

iterations = 10_000

# Test atomic version
shm_atomic = Semian::SharedMemory.new(:bench_atomic, key: 0xAA000001, size: 16)
time_atomic = benchmark_increments(shm_atomic, iterations: iterations, label: "Atomic (lock-free)")
shm_atomic.destroy

# Test locked version
shm_locked = Semian::SharedMemoryLocked.new(:bench_locked, key: 0xBB000001, size: 16)
time_locked = benchmark_increments(shm_locked, iterations: iterations, label: "Locked (semaphore)")
shm_locked.destroy

puts "=" * 80
puts "COMPARISON"
puts "=" * 80
puts "Atomic time: #{time_atomic} μs"
puts "Locked time: #{time_locked} μs"
puts "Speedup: #{(time_locked.to_f / time_atomic).round(1)}x faster with atomics"
puts "Overhead per operation: #{((time_locked - time_atomic).to_f / iterations).round(3)} μs"
puts "=" * 80
