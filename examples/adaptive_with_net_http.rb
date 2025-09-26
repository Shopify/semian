#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "semian"
require "semian/net_http"
require "net/http"

# Example of using the adaptive circuit breaker with Net::HTTP adapter

puts "=" * 60
puts "Adaptive Circuit Breaker with Net::HTTP Example"
puts "=" * 60

# Configure a mock HTTP server endpoint
# In real usage, this would be your actual service endpoint
TEST_HOST = "httpbin.org"
TEST_PORT = 443

# Configure Semian for the HTTP endpoint with adaptive circuit breaker
puts "\nConfiguring Semian with adaptive circuit breaker..."

# The Net::HTTP adapter will automatically use this configuration
# when making requests to the specified host
Semian.register(
  "httpbin_service",
  adaptive_circuit_breaker: true, # Enable adaptive circuit breaker
  bulkhead: true,
  tickets: 5,
  timeout: 1,
)

# Helper method to make HTTP requests
def make_request(path = "/status/200")
  uri = URI("https://#{TEST_HOST}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 2
  http.open_timeout = 2

  # Configure semian for this connection
  # This would typically be done in your HTTP client configuration
  http.singleton_class.class_eval do
    def semian_identifier
      "httpbin_service"
    end

    def semian_options
      # Return the resource name to use the registered configuration
      { name: "httpbin_service" }
    end
  end

  request = Net::HTTP::Get.new(uri)
  response = http.request(request)
  response.code
end

puts "Configuration complete!"

# Simulate some requests
puts "\nPhase 1: Normal operation (successful requests)"
puts "-" * 40

3.times do |i|
  begin
    code = make_request("/status/200")
    puts "Request #{i + 1}: Success (HTTP #{code})"
  rescue => e
    puts "Request #{i + 1}: Error - #{e.class}: #{e.message}"
  end
  sleep(0.5)
end

puts "\nPhase 2: Simulating errors (requesting error status codes)"
puts "-" * 40

5.times do |i|
  begin
    # Request error status codes to trigger circuit breaker logic
    code = make_request("/status/500")
    puts "Request #{i + 1}: Got HTTP #{code}"
  rescue Net::HTTPServerException => e
    puts "Request #{i + 1}: HTTP Error - #{e.message}"
  rescue Semian::OpenCircuitError => e
    puts "Request #{i + 1}: Circuit Open - #{e.message}"
  rescue => e
    puts "Request #{i + 1}: Error - #{e.class}: #{e.message}"
  end
  sleep(0.5)
end

# Get metrics from the resource
if resource = Semian["httpbin_service"]
  if resource.circuit_breaker.respond_to?(:metrics)
    puts "\nCircuit breaker metrics:"
    metrics = resource.circuit_breaker.metrics
    puts "  Rejection rate: #{(metrics[:rejection_rate] * 100).round(2)}%"
    puts "  Error rate: #{(metrics[:error_rate] * 100).round(2)}%"
    puts "  Health metric P: #{metrics[:health_metric].round(3)}"
  end
end

puts "\nPhase 3: Recovery (back to successful requests)"
puts "-" * 40

3.times do |i|
  begin
    code = make_request("/status/200")
    puts "Request #{i + 1}: Success (HTTP #{code})"
  rescue Semian::OpenCircuitError => e
    puts "Request #{i + 1}: Still rejected - #{e.message}"
  rescue => e
    puts "Request #{i + 1}: Error - #{e.class}: #{e.message}"
  end
  sleep(0.5)
end

# Clean up
Semian.destroy("httpbin_service")

puts "\n" + "=" * 60
puts "Example complete!"
puts "=" * 60

puts "\nKey Points:"
puts "- The adaptive circuit breaker works seamlessly with existing adapters"
puts "- It monitors request success/failure rates automatically"
puts "- Background health checks help detect recovery"
puts "- The rejection rate adjusts dynamically based on service health"
