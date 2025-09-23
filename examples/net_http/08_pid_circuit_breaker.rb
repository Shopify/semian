# frozen_string_literal: true

require "bundler/setup"
require "semian"
require "semian/pid_circuit_breaker"
require "semian/net_http"
require "net/http"
require "timeout"
require_relative "../colors"

# Example demonstrating the PID Circuit Breaker with Partial Opening
#
# This advanced circuit breaker uses:
# - Partial rejection: Instead of binary open/closed, it rejects a percentage of requests
# - Health check pings: Proactively monitors service health
# - Adaptive throttling: Smoothly adjusts rejection rate based on conditions
#
# The P (Proportional) value directly controls the rejection percentage,
# influenced by both error rate and ping success vs rejection rate difference.

puts colorize(:light_blue, "PID Circuit Breaker with Partial Opening Example")
puts colorize(:light_blue, "=" * 50)
puts

# Configure Semian with PID Circuit Breaker
module Semian
  class << self
    alias_method :original_create_circuit_breaker, :create_circuit_breaker

    def create_circuit_breaker(name, **options)
      # Use PID circuit breaker if specified
      if options[:circuit_breaker_type] == :pid
        return if ENV.key?("SEMIAN_CIRCUIT_BREAKER_DISABLED")
        return unless options.fetch(:circuit_breaker, true)

        exceptions = options[:exceptions] || []
        breaker = PIDCircuitBreaker.new(
          name,
          exceptions: Array(exceptions) + [::Semian::BaseError],
          error_timeout: options[:error_timeout] || 3,
          implementation: implementation(**options),
          half_open_resource_timeout: options[:half_open_resource_timeout],
          # PID specific parameters
          pid_kp: options[:pid_kp] || 1.0,
          pid_ki: options[:pid_ki] || 0.1,
          pid_kd: options[:pid_kd] || 0.05,
          error_rate_setpoint: options[:error_rate_setpoint] || 0.05,
          sample_window_size: options[:sample_window_size] || 100,
          min_requests: options[:min_requests] || 10,
          # Partial opening parameters
          max_rejection_rate: options[:max_rejection_rate] || 0.95,
          # Ping parameters
          ping_interval: options[:ping_interval] || 1.0,
          ping_timeout: options[:ping_timeout] || 0.5,
          ping_weight: options[:ping_weight] || 0.3,
        )

        # Configure ping if provided
        if options[:ping_proc]
          breaker.configure_ping(&options[:ping_proc])
        end

        breaker
      else
        original_create_circuit_breaker(name, **options)
      end
    end
  end
end

# Configure HTTP client with PID Circuit Breaker
Semian::NetHTTP.default_configuration = proc do |host, port|
  if host == "example.com"
    config = {
      name: "example_api",
      circuit_breaker: true,
      circuit_breaker_type: :pid,

      # PID Controller tuning
      pid_kp: 2.0,      # Proportional gain - controls rejection sensitivity
      pid_ki: 0.1,      # Integral gain - accumulates error history
      pid_kd: 0.05,     # Derivative gain - responds to rate of change

      # Target 5% error rate or less
      error_rate_setpoint: 0.05,

      # Maximum rejection rate (95% - always let some requests through)
      max_rejection_rate: 0.95,

      # Track last 50 requests
      sample_window_size: 50,

      # Need at least 5 requests before evaluating
      min_requests: 5,

      # Ping configuration
      ping_interval: 0.5, # Check health every 0.5 seconds
      ping_timeout: 0.3,     # Ping timeout
      ping_weight: 0.3,      # How much pings affect rejection rate

      # Also configure bulkhead
      bulkhead: true,
      tickets: 5,
      timeout: 1,
    }

    # Configure health check ping
    config[:ping_proc] = lambda do
      uri = URI("https://example.com/status/200")
      response = Net::HTTP.get_response(uri)
      response.code == "200"
    rescue
      false
    end

    config
  end
end

# Helper to make HTTP requests
def make_request(url, should_fail: false)
  uri = URI(url)

  uri.path = if should_fail
    # Simulate a failing endpoint
    "/status/500"
  else
    "/status/200"
  end

  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    request = Net::HTTP::Get.new(uri)
    response = http.request(request)
    response.code == "200"
  end
rescue => e
  raise e
end

# Get the circuit breaker for monitoring
circuit = Semian["example_api"]&.circuit_breaker

# Helper to display circuit status
def display_status(circuit)
  if circuit
    rejection = (circuit.rejection_rate * 100).round(1)
    error_rate = (circuit.current_error_rate * 100).round(1)
    ping_success = (circuit.ping_success_rate * 100).round(1)
    p_value = circuit.p_value.round(3)

    status = if circuit.closed?
      colorize(:green, "CLOSED")
    elsif circuit.partially_open?
      colorize(:yellow, "PARTIAL")
    else
      colorize(:red, "BLOCKING")
    end

    " [#{status} Rej:#{rejection}% Err:#{error_rate}% Ping:#{ping_success}% P:#{p_value}]"
  else
    ""
  end
end

# Scenario 1: Normal operation with low error rate
puts colorize(:green, "Scenario 1: Normal Operation (2% errors)")
puts colorize(:gray, "Making requests with low error rate...")

successes = 0
failures = 0
rejections = 0

50.times do |i|
  should_fail = (i % 50 == 0) # 2% failure rate

  begin
    result = make_request("https://example.com", should_fail: should_fail)
    successes += 1
    print(colorize(:green, "✓"))
  rescue Semian::OpenCircuitError => e
    rejections += 1
    print(colorize(:yellow, "⊗")) # Rejected by circuit
  rescue => e
    failures += 1
    print(colorize(:red, "✗"))
  end

  print(display_status(circuit)) if i % 10 == 9
end

puts
puts colorize(:green, "→ Successes: #{successes}, Failures: #{failures}, Rejections: #{rejections}")
puts colorize(:green, "→ Circuit remains mostly CLOSED with minimal rejection")
puts

# Wait for pings to stabilize
sleep(1)

# Scenario 2: Gradual increase in errors
puts colorize(:yellow, "Scenario 2: Gradual Error Increase")
puts colorize(:gray, "Slowly increasing error rate from 5% to 30%...")

successes = 0
failures = 0
rejections = 0

60.times do |i|
  # Gradually increase error rate
  error_probability = 0.05 + (i.to_f / 60 * 0.25)
  should_fail = rand < error_probability

  begin
    result = make_request("https://example.com", should_fail: should_fail)
    successes += 1
    print(colorize(:green, "✓"))
  rescue Semian::OpenCircuitError => e
    rejections += 1
    print(colorize(:yellow, "⊗"))
  rescue => e
    failures += 1
    print(colorize(:red, "✗"))
  end

  print(display_status(circuit)) if i % 10 == 9
end

puts
puts colorize(:yellow, "→ Successes: #{successes}, Failures: #{failures}, Rejections: #{rejections}")
puts colorize(:yellow, "→ Circuit gradually increases rejection rate as errors rise")
puts

# Scenario 3: Recovery phase
puts colorize(:green, "Scenario 3: Recovery Phase")
puts colorize(:gray, "All successful requests to recover...")

# Reset counters
successes = 0
failures = 0
rejections = 0

40.times do |i|
  begin
    # All successful requests
    result = make_request("https://example.com", should_fail: false)
    successes += 1
    print(colorize(:green, "✓"))
  rescue Semian::OpenCircuitError => e
    rejections += 1
    print(colorize(:yellow, "⊗"))
  rescue => e
    failures += 1
    print(colorize(:red, "✗"))
  end

  print(display_status(circuit)) if i % 10 == 9
end

puts
puts colorize(:green, "→ Successes: #{successes}, Failures: #{failures}, Rejections: #{rejections}")
puts colorize(:green, "→ Rejection rate decreases as health improves")
puts

# Scenario 4: Ping influence on rejection
puts colorize(:blue, "Scenario 4: Health Check Ping Influence")
puts colorize(:gray, "Moderate errors but good ping results...")

# Configure successful pings
if circuit
  circuit.configure_ping do
    true  # Always successful for this test
  end
end

sleep(1)  # Let pings accumulate

successes = 0
failures = 0
rejections = 0

30.times do |i|
  # 15% error rate
  should_fail = (i % 7 == 0)

  begin
    result = make_request("https://example.com", should_fail: should_fail)
    successes += 1
    print(colorize(:green, "✓"))
  rescue Semian::OpenCircuitError => e
    rejections += 1
    print(colorize(:yellow, "⊗"))
  rescue => e
    failures += 1
    print(colorize(:red, "✗"))
  end

  print(display_status(circuit)) if i % 10 == 9
end

puts
puts colorize(:blue, "→ Successes: #{successes}, Failures: #{failures}, Rejections: #{rejections}")
puts colorize(:blue, "→ Good ping results help reduce rejection rate despite errors")
puts

# Now simulate failing pings
puts colorize(:orange, "Now with failing health checks...")

if circuit
  circuit.configure_ping do
    false # Always fail for this test
  end
end

sleep(1) # Let failing pings accumulate

successes = 0
failures = 0
rejections = 0

30.times do |i|
  # Same 15% error rate
  should_fail = (i % 7 == 0)

  begin
    result = make_request("https://example.com", should_fail: should_fail)
    successes += 1
    print(colorize(:green, "✓"))
  rescue Semian::OpenCircuitError => e
    rejections += 1
    print(colorize(:yellow, "⊗"))
  rescue => e
    failures += 1
    print(colorize(:red, "✗"))
  end

  print(display_status(circuit)) if i % 10 == 9
end

puts
puts colorize(:orange, "→ Successes: #{successes}, Failures: #{failures}, Rejections: #{rejections}")
puts colorize(:orange, "→ Failed pings increase rejection rate for same error rate")
puts

# Summary
puts
puts colorize(:light_blue, "=" * 50)
puts colorize(:light_blue, "PID Circuit Breaker with Partial Opening Summary:")
puts colorize(:white, "• Partial Rejection: Rejects % of requests based on P value")
puts colorize(:white, "• No Binary States: Smooth throttling instead of open/closed")
puts colorize(:white, "• Health Pings: Proactive monitoring affects rejection rate")
puts colorize(:white, "• Adaptive: P term includes error rate AND ping/rejection difference")
puts colorize(:white, "• Graceful Degradation: Always allows some requests through")
puts
puts colorize(:gray, "Key advantages over traditional circuit breakers:")
puts colorize(:gray, "  - No sudden traffic drops (partial vs full blocking)")
puts colorize(:gray, "  - Proactive health monitoring via pings")
puts colorize(:gray, "  - Self-balancing based on actual vs expected performance")
puts colorize(:gray, "  - Better for gradually degrading services")
