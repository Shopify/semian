#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "semian"
require "semian/net_http"
require "net/http"

# Example: Dual Circuit Breaker with Net::HTTP
# This shows how to run both legacy and adaptive circuit breakers in parallel
# and switch between them at runtime using a callable that determines which to use.

# Simulate a feature flag system (in production, this would be your actual feature flag service)
module ExperimentFlags
  @enabled = false

  def self.enable_adaptive!
    @enabled = true
  end

  def self.disable_adaptive!
    @enabled = false
  end

  def self.use_adaptive_circuit_breaker?
    @enabled
  end
end

# Helper function to print state of all Semian objects between each phase
def print_semian_state
  puts "\n=== Semian Resources State ===\n"
  Semian.resources.values.each do |resource|
    puts "Resource: #{resource.name}"

    # Bulkhead info
    if resource.bulkhead
      puts "  Bulkhead: tickets=#{resource.tickets}, count=#{resource.count}"
    else
      puts "  Bulkhead: disabled"
    end

    # Circuit breaker info
    cb = resource.circuit_breaker
    if cb.nil?
      puts "  Circuit Breaker: disabled"
    elsif cb.is_a?(Semian::DualCircuitBreaker)
      puts "  Circuit Breaker: DualCircuitBreaker"
      metrics = cb.metrics
      puts "    Active: #{metrics[:active]}"
      puts "    Classic: state=#{metrics[:classic][:state]}, open=#{metrics[:classic][:open]}, half_open=#{metrics[:classic][:half_open]}"
      puts "    Adaptive: rejection_rate=#{metrics[:adaptive][:rejection_rate]}, error_rate=#{metrics[:adaptive][:error_rate]}"
    elsif cb.is_a?(Semian::AdaptiveCircuitBreaker)
      puts "  Circuit Breaker: AdaptiveCircuitBreaker"
      puts "    open=#{cb.open?}, closed=#{cb.closed?}, half_open=#{cb.half_open?}"
    else
      puts "  Circuit Breaker: Legacy"
      puts "    state=#{cb.state&.value}, open=#{cb.open?}, closed=#{cb.closed?}, half_open=#{cb.half_open?}"
      puts "    last_error=#{cb.last_error&.class}"
    end
    puts ""
  end
  puts "=== END STATE OUTPUT ===\n\n"
end

Semian::DualCircuitBreaker.adaptive_circuit_breaker_selector(->(_resource) { ExperimentFlags.use_adaptive_circuit_breaker? })

# Configure Semian with dual circuit breaker
Semian::NetHTTP.semian_configuration = proc do |host, port|
  # Example: only enable for specific host
  if host == "shopify-debug.com"
    {
      # Enable dual circuit breaker mode
      dual_circuit_breaker: true,

      # Legacy circuit breaker settings (required)
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 5,

      # Adaptive circuit breaker settings (uses defaults if not specified)
      seed_error_rate: 0.01,

      # Bulkhead settings
      tickets: 3,
      timeout: 1,

      # Exceptions to track
      exceptions: [Net::HTTPServerException],
    }
  end
end

puts "=== Dual Circuit Breaker with Net::HTTP ===\n\n"

# Helper to make HTTP requests
def make_request(uri_str)
  uri = URI(uri_str)
  Net::HTTP.start(uri.host, uri.port) do |http|
    request = Net::HTTP::Get.new(uri)
    response = http.request(request)
    response.code
  end
rescue => e
  e.class.name
end

print_semian_state

# Phase 1: Use legacy circuit breaker
puts "Phase 1: Using LEGACY circuit breaker"
puts "-" * 50
ExperimentFlags.disable_adaptive!

3.times do |i|
  puts "Request #{i + 1} (using legacy)..."
  result = make_request("http://shopify-debug.com/")
  puts "  Result: #{result}\n\n"
  sleep 3
end

print_semian_state

# Phase 2: Switch to adaptive circuit breaker
puts "Phase 2: Switching to ADAPTIVE circuit breaker"
puts "-" * 50
ExperimentFlags.enable_adaptive!

3.times do |i|
  puts "Request #{i + 1} (using adaptive)..."
  result = make_request("http://shopify-debug.com/")
  puts "  Result: #{result}\n\n"
  sleep 3
end

print_semian_state

# Phase 3: Demonstrate dynamic switching
puts "Phase 3: Dynamic switching during runtime"
puts "-" * 50

5.times do |i|
  # Toggle between legacy and adaptive
  if i.even?
    ExperimentFlags.disable_adaptive!
    active = "LEGACY"
  else
    ExperimentFlags.enable_adaptive!
    active = "ADAPTIVE"
  end

  puts "Request #{i + 1} (using #{active})..."
  result = make_request("http://shopify-debug.com/")
  puts "  Result: #{result}\n\n"
  sleep 3
end

print_semian_state

puts "=== Demo Complete ===\n\n"
puts "Key Benefits of Dual Circuit Breaker:"
puts "  1. Both breakers track all requests independently"
puts "  2. Can switch between breakers without losing state"
puts "  3. Can compare behavior of both approaches with same traffic"
puts "  4. Enables gradual rollout with instant rollback capability"
puts "  5. Perfect for A/B testing circuit breaker strategies"
