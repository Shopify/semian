#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "semian", path: File.expand_path("..", __dir__)
end

require "semian"
require "logger"

# Setup logging
Semian.logger = Logger.new($stdout)
Semian.logger.level = Logger::INFO

# Example error class
class ServiceError < StandardError; end

# Register a resource with exponential backoff
resource = Semian.register(
  :external_service,
  # Circuit breaker configuration
  bulkhead: false, # Disable bulkhead for this example
  exceptions: [ServiceError],
  error_threshold: 2,
  success_threshold: 2,

  # Enable dynamic timeout instead of fixed error_timeout
  dynamic_timeout: true,
  # NOTE: error_timeout is not specified since we're using dynamic timeout
)

puts "=" * 60
puts "Dynamic Timeout Circuit Breaker Example"
puts "=" * 60
puts

# Helper method to simulate a service call
def make_request(resource, should_fail: false, message: "")
  puts "#{Time.now.strftime("%H:%M:%S.%3N")} - #{message}"

  begin
    resource.acquire do
      if should_fail
        raise ServiceError, "Service is temporarily unavailable"
      else
        puts "  ✓ Request successful"
        "success"
      end
    end
  rescue Semian::OpenCircuitError
    puts "  ✗ Circuit is OPEN - request rejected immediately"
  rescue ServiceError => e
    puts "  ✗ Request failed: #{e.message}"
  end

  puts
end

puts "Initial state: Circuit is CLOSED"
puts

# Trigger errors to open the circuit
puts "Step 1: Triggering errors to open the circuit..."
2.times do |i|
  make_request(resource, should_fail: true, message: "Error #{i + 1}")
end

puts "Circuit is now OPEN (first open, backoff = 500ms)"
puts

# Wait less than initial backoff
puts "Step 2: Waiting 400ms (less than backoff)..."
sleep 0.4
make_request(resource, message: "Attempting request (should be rejected)")

# Wait for initial backoff to expire
puts "Step 3: Waiting another 200ms (total 600ms > 500ms backoff)..."
sleep 0.2
puts "Circuit should now be HALF-OPEN"
make_request(resource, should_fail: true, message: "Request in half-open state (will fail)")

puts "Circuit is OPEN again (consecutive failure, backoff = 1s)"
puts

# Wait for doubled backoff
puts "Step 4: Waiting 1.1s for doubled backoff to expire..."
sleep 1.1
puts "Circuit should now be HALF-OPEN again"

# Now succeed to start closing the circuit
puts "Step 5: Making successful requests to close the circuit..."
2.times do |i|
  make_request(resource, should_fail: false, message: "Success #{i + 1}")
end

puts "Circuit is now CLOSED (backoff reset to 500ms for next time)"
puts

# Open circuit again to show reset
puts "Step 6: Opening circuit again to show backoff reset..."
2.times do |i|
  make_request(resource, should_fail: true, message: "Error #{i + 1}")
end

puts "Circuit is OPEN again (backoff reset to initial 500ms)"
puts

puts "=" * 60
puts "Example Complete!"
puts "=" * 60
puts
puts "Key observations:"
puts "1. Initial error_timeout started at 500ms"
puts "2. After consecutive failure in half-open state, error_timeout doubled to 1s"
puts "3. After circuit closed successfully, error_timeout reset to 500ms"
puts
puts "Timeout progression (hybrid approach):"
puts "- Exponential phase: 0.5s → 1s → 2s → 4s → 8s → 16s → 20s"
puts "  (Doubles each time until reaching 20s threshold)"
puts "- Linear phase: 20s → 21s → 22s → 23s → ... → 60s"
puts "  (Adds 1s each time until reaching 60s maximum)"
puts
puts "Benefits over fixed timeout:"
puts "- Faster recovery detection (starts at 500ms instead of guessing a value)"
puts "- Quick initial retries for transient failures (exponential phase)"
puts "- More reasonable progression for persistent outages (linear phase)"
puts "- No manual tuning required - adapts to actual service behavior"
puts
puts "Implementation details:"
puts "- Uses the same error_timeout field, dynamically adjusts it based on failures"
puts "- Exponential increase (×2) until 20s, then linear increase (+1s) until 60s"
puts "- Resets to initial value when circuit closes (service recovers)"
puts "- Simple and elegant hybrid solution!"
