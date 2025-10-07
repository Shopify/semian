# Semian Experimental Resource

This directory contains an experimental resource adapter for running complex experiments with Semian.

## Overview

The `ExperimentalResource` class simulates a distributed service with multiple endpoints, each with configurable latencies following statistical distributions. This allows for testing various failure scenarios and performance characteristics.

## Features

### Current Implementation

1. **Multiple Endpoints**: Configure any number of endpoints, each with its own fixed latency
2. **Statistical Distributions**: Latencies are assigned based on statistical distributions
   - Currently supports: Log-normal distribution
3. **Latency Bounds**: Set minimum and maximum latency constraints
4. **Fixed Latencies**: Each endpoint gets a fixed latency at initialization for consistent behavior
5. **Request Timeouts**: Configure a maximum timeout for requests
   - Requests that would exceed the timeout sleep for the timeout period then raise an exception
   - Useful for simulating real-world timeout behavior
6. **Baseline Error Rate**: Configure a probability of request failure
   - Requests fail randomly based on the configured error rate
   - Failed requests throw `RequestError` exceptions after partial processing
7. **Service-Wide Degradation**: Degrade the entire service with optional ramp-up time
   - **Latency degradation**: Add fixed latency to all requests
   - **Error rate changes**: Modify error rate for the entire service
   - **Gradual ramp-up**: Both degradations support gradual transitions over time

## Usage

```ruby
require_relative "experimental_resource"

# Create a resource with 5 endpoints, timeout, and error rate
resource = Semian::Experiments::ExperimentalResource.new(
  name: "experiment_service",
  endpoints_count: 5,
  min_latency: 0.01,  # 10ms minimum
  max_latency: 1.0,   # 1s maximum
  distribution: {
    type: :log_normal,
    mean: 0.1,        # 100ms average
    std_dev: 0.05     # 50ms standard deviation
  },
  timeout: 0.5,       # 500ms timeout (optional)
  error_rate: 0.1     # 10% error rate (optional)
)

# Make a request to endpoint 0
begin
  result = resource.request(0)
  puts "Latency: #{result[:latency]}s"
rescue Semian::Experiments::ExperimentalResource::TimeoutError => e
  puts "Request timed out: #{e.message}"
rescue Semian::Experiments::ExperimentalResource::RequestError => e
  puts "Request failed: #{e.message}"
end

# Service-wide degradation methods

# Add latency to all requests (immediate)
resource.add_latency(0.2)  # Add 200ms to all requests

# Add latency with gradual ramp-up
resource.add_latency(0.5, ramp_time: 10)  # Ramp up to +500ms over 10 seconds

# Change error rate (immediate)
resource.set_error_rate(0.3)  # 30% error rate

# Change error rate with gradual ramp-up
resource.set_error_rate(0.5, ramp_time: 5)  # Ramp up to 50% errors over 5 seconds

# Check current degradation levels
current_latency = resource.current_latency_degradation  # Returns added latency in seconds
current_error = resource.current_error_rate             # Returns current error rate (0.0-1.0)

# Reset service to baseline
resource.reset_degradation

# Get base latency for an endpoint (without degradation effects)
base_latency = resource.base_latency(0)

# Timeout-related methods
resource.would_timeout?(3)     # Check if endpoint 3 would timeout
resource.timeout_endpoints     # Get array of all endpoints that would timeout
```

### Using with Semian Circuit Breaker

The experimental resource integrates seamlessly with Semian's circuit breaker:

```ruby
# Register a Semian circuit breaker configuration
Semian.register(
  :my_service,
  success_threshold: 2,    # Close circuit after 2 successes
  error_threshold: 3,      # Open circuit after 3 errors
  error_timeout: 5,        # Wait 5 seconds before retrying
  bulkhead: false,
  exceptions: [
    Semian::Experiments::ExperimentalResource::RequestError,
    Semian::Experiments::ExperimentalResource::TimeoutError
  ]
)

# Get the Semian resource
semian = Semian[:my_service]

# Use with circuit breaker protection
begin
  semian.acquire do
    resource.request(0)
  end
rescue Semian::OpenCircuitError => e
  puts "Circuit is open - failing fast!"
end

# Or configure circuit breaker directly on resource initialization
resource = Semian::Experiments::ExperimentalResource.new(
  name: "protected_service",
  endpoints_count: 5,
  # ... other config ...
  # Semian options (will use acquire_semian_resource internally)
  success_threshold: 3,
  error_threshold: 3,
  error_timeout: 5
)

# When Semian is configured, requests automatically use circuit breaker
resource.request(0)  # Protected by circuit breaker
```

## Distribution Configuration

### Log-Normal Distribution

The log-normal distribution is useful for modeling latencies as it:
- Is always positive (latencies can't be negative)
- Has a long tail (occasional slow requests)
- Matches real-world latency patterns

Configuration:
```ruby
distribution: {
  type: :log_normal,
  mean: 0.1,      # Mean of the distribution (in seconds)
  std_dev: 0.05   # Standard deviation (in seconds)
}
```

## Examples

### Basic Usage
See `example_usage.rb` for a complete working example that demonstrates:
- Creating a resource with multiple endpoints
- Making requests to specific endpoints
- Statistical analysis of latency distribution
- ASCII histogram visualization

### Service Degradation
See `example_service_degradation.rb` for demonstrating service-wide degradation:
- Immediate latency increases across all endpoints
- Gradual latency degradation with ramp-up time
- Error rate changes with optional ramp-up
- Combined degradation effects (latency + errors)
- Realistic failure scenario simulation
- Service recovery patterns

### Circuit Breaker Integration
See `example_semian_circuit_breaker_simple.rb` for using Semian's circuit breaker:
- Integration with Semian's production-ready circuit breaker
- Automatic circuit opening after error threshold
- Fail-fast behavior when circuit is open
- Half-open state for recovery testing
- Circuit closes after success threshold
- Complete example with gradual degradation

### Timeout Behavior
See `example_timeout.rb` for demonstrating timeout functionality:
- Configuring request timeouts
- Identifying which endpoints would timeout
- Handling timeout exceptions
- Analyzing timeout rates across different threshold values

### Graphical Visualization
See `example_with_svg_graph.rb` for generating graphical charts:
- SVG histogram of latency distribution
- Cumulative distribution function (CDF) chart
- No external dependencies required (pure Ruby/SVG)
- View the generated `.svg` files in any web browser

For more advanced graphing with external libraries, see `example_with_graph.rb` (requires the `gruff` gem)

## Future Enhancements

Potential additions for future requirements:
- Additional statistical distributions (uniform, exponential, normal, etc.)
- Dynamic latency changes over time
- Advanced failure injection patterns
- Request rate limiting
- Custom degradation multipliers
- Endpoint health monitoring
- Bulkhead pattern integration
- Metrics and monitoring integration
