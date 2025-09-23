# PID Circuit Breaker with Partial Opening

## Overview

The PID Circuit Breaker is an advanced circuit breaker implementation that uses a PID (Proportional-Integral-Derivative) controller algorithm with **partial opening** instead of traditional binary states. This circuit breaker continuously throttles traffic by rejecting a percentage of requests based on system stress, rather than blocking all requests when a threshold is exceeded.

## Key Features

### Partial Opening
- **No Binary States**: Instead of open/closed/half-open states, the circuit rejects 0-100% of requests
- **Smooth Throttling**: Rejection rate is directly controlled by the P (proportional) value
- **Graceful Degradation**: Always allows some requests through (configurable maximum rejection rate)
- **Probabilistic Rejection**: Each request has a probability of rejection based on current stress

### Health Check Pings
- **Proactive Monitoring**: Periodically sends health check pings to the service
- **Adaptive Adjustment**: Ping success rate influences the rejection rate
- **Self-Balancing**: If pings succeed but we're rejecting traffic, the circuit reduces rejection
- **Early Detection**: Can detect service recovery before normal traffic resumes

## How It Works

### The P (Proportional) Value

The P value directly controls the rejection percentage and is calculated as:

```
P = Kp × (error_rate - setpoint + ping_weight × (rejection_rate - ping_success_rate))
```

This means:
- High error rate → Higher P value → More rejections
- If rejecting more than ping success suggests → P value decreases
- If ping success is high but still rejecting → Circuit self-corrects

### Rejection Rate Calculation

```
rejection_rate = clamp(P_value, 0, max_rejection_rate)
```

With smoothing applied to avoid sudden changes:
```
rejection_rate = α × new_rate + (1-α) × current_rate
```

### Components

#### Proportional (P) Component
- Responds to current error rate AND ping/rejection difference
- Directly controls rejection percentage
- Formula: `P = Kp × (error + ping_weight × rejection_difference)`

#### Integral (I) Component
- Accumulates errors over time
- Helps detect sustained problems
- Formula: `I = Ki × ∫(error)dt`

#### Derivative (D) Component
- Responds to rate of change in errors
- Provides trend detection
- Formula: `D = Kd × d(error)/dt`

## Configuration

### Basic Setup

```ruby
require 'semian/pid_circuit_breaker'

circuit = Semian::PIDCircuitBreaker.new(
  :service_name,
  exceptions: [Net::ReadTimeout, Net::OpenTimeout],
  error_timeout: 10,  # Kept for compatibility
  implementation: ::Semian::ThreadSafe,
)
```

### PID Tuning Parameters

```ruby
pid_kp: 1.0,              # Proportional gain (default: 1.0)
pid_ki: 0.1,              # Integral gain (default: 0.1)
pid_kd: 0.05,             # Derivative gain (default: 0.05)
error_rate_setpoint: 0.05 # Target error rate, 5% (default: 0.05)
```

### Partial Opening Parameters

```ruby
max_rejection_rate: 0.95  # Maximum rejection rate (default: 0.95)
                          # Ensures at least 5% of requests get through
```

### Ping Configuration

```ruby
ping_interval: 1.0,    # Seconds between pings (default: 1.0)
ping_timeout: 0.5,     # Ping timeout in seconds (default: 0.5)
ping_weight: 0.3,      # How much pings affect P term (0.0-1.0, default: 0.3)
```

### Control Parameters

```ruby
sample_window_size: 100,  # Number of requests to track (default: 100)
min_requests: 10,         # Minimum requests before evaluation (default: 10)
```

## Usage Example

```ruby
require 'semian/pid_circuit_breaker'
require 'net/http'

# Create circuit breaker with partial opening
circuit = Semian::PIDCircuitBreaker.new(
  :payment_service,
  exceptions: [Timeout::Error, Errno::ECONNREFUSED],
  error_timeout: 30,
  implementation: ::Semian::ThreadSafe,

  # PID tuning
  pid_kp: 2.0,      # Higher gain for more responsive rejection
  pid_ki: 0.1,
  pid_kd: 0.05,

  # Partial opening settings
  error_rate_setpoint: 0.02,  # 2% error rate target
  max_rejection_rate: 0.90,   # Never reject more than 90%

  # Ping configuration
  ping_interval: 0.5,
  ping_timeout: 0.3,
  ping_weight: 0.4,  # 40% influence from ping results

  sample_window_size: 200,
  min_requests: 20
)

# Configure health check ping
circuit.configure_ping do
  begin
    # Your health check logic here
    uri = URI('https://payment-service.example.com/health')
    response = Net::HTTP.get_response(uri)
    response.code == '200'
  rescue => e
    false
  end
end

# Use the circuit breaker
begin
  circuit.acquire do
    # Make your external service call here
    PaymentService.process_payment(order)
  end
rescue Semian::OpenCircuitError => e
  # Request was rejected (probabilistically)
  # e.message includes current rejection rate
  handle_rejection(e)
rescue Timeout::Error => e
  # Actual service error
  handle_service_error(e)
end
```

## Monitoring

The PID circuit breaker provides detailed metrics:

```ruby
# Current rejection rate (0.0 to 1.0)
circuit.rejection_rate  # e.g., 0.25 for 25% rejection

# Current error rate from actual requests
circuit.current_error_rate  # e.g., 0.05 for 5% errors

# Ping success rate
circuit.ping_success_rate  # e.g., 0.95 for 95% successful pings

# PID component values
circuit.p_value  # Proportional component (controls rejection)
circuit.i_value  # Integral component
circuit.d_value  # Derivative component

# Circuit state (based on rejection rate)
circuit.closed?          # < 1% rejection
circuit.partially_open?  # 1-99% rejection
circuit.open?           # >= 99% rejection
```

## Tuning Guide

### Understanding Partial Opening

The rejection rate is directly controlled by the P value:
- `P = 0.0` → 0% rejection (fully open)
- `P = 0.5` → 50% rejection (half traffic blocked)
- `P = 1.0` → 100% rejection (capped by max_rejection_rate)

### Ping Weight

Controls how much health check results influence rejection:
- `ping_weight = 0.0`: Pings don't affect rejection (pure error-based)
- `ping_weight = 0.5`: Equal weight to errors and ping/rejection difference
- `ping_weight = 1.0`: Ping results dominate (not recommended)

### Common Configurations

#### Aggressive Throttling
For services that need quick response to problems:
```ruby
pid_kp: 3.0,              # High gain for quick rejection
max_rejection_rate: 0.95, # Can reject up to 95%
ping_weight: 0.2,         # Less ping influence
min_requests: 5           # Quick evaluation
```

#### Conservative Throttling
For services that should rarely reject:
```ruby
pid_kp: 0.5,              # Low gain for gradual response
max_rejection_rate: 0.50, # Never reject more than 50%
ping_weight: 0.5,         # High ping influence
min_requests: 20          # More data before acting
```

#### Ping-Dominated
For services where health checks are very reliable:
```ruby
pid_kp: 1.0,
ping_weight: 0.7,         # Pings heavily influence rejection
ping_interval: 0.5,       # Frequent pings
ping_timeout: 0.2         # Quick ping timeout
```

## Advantages Over Traditional Circuit Breakers

### Partial Opening Benefits

1. **No Traffic Cliffs**: Gradual throttling instead of sudden cutoffs
2. **Always Some Traffic**: Even at maximum stress, some requests get through
3. **Self-Correcting**: Ping results help balance rejection rate
4. **Better User Experience**: Some users succeed even during problems
5. **Faster Recovery Detection**: Pings detect recovery before normal traffic

### When to Use Partial Opening

Ideal for:
- Services with variable capacity
- Gradual degradation scenarios
- User-facing services where some success is better than none
- Services with good health check endpoints
- Microservices with complex dependencies

### When NOT to Use

Consider traditional circuit breakers for:
- Services that must be fully available or fully unavailable
- When partial success could cause data inconsistency
- Services without reliable health checks
- When predictable behavior is more important than availability

## Debugging

Enable debug logging to see detailed calculations:

```bash
SEMIAN_DEBUG_PID=1 ruby your_app.rb
```

This logs:
- PID calculations (P, I, D values)
- Rejection rate updates
- Ping results and influence
- Error rates and differences

## Migration from Traditional Circuit Breaker

To migrate existing circuit breakers:

1. **Start Conservative**: Begin with low Kp and high max_rejection_rate
2. **Add Health Checks**: Implement reliable ping endpoints
3. **Monitor Metrics**: Track rejection rates and user impact
4. **Tune Gradually**: Adjust gains based on observed behavior
5. **Increase Ping Weight**: As confidence in health checks grows

Example migration path:
```ruby
# Week 1: Very conservative
pid_kp: 0.3, max_rejection_rate: 0.20, ping_weight: 0.1

# Week 2: Increase responsiveness
pid_kp: 0.7, max_rejection_rate: 0.40, ping_weight: 0.2

# Week 3: Production ready
pid_kp: 1.5, max_rejection_rate: 0.80, ping_weight: 0.3
```

## Best Practices

1. **Always Configure Pings**: Health checks provide crucial feedback
2. **Start with Low Gains**: Better to under-react than over-react
3. **Monitor Rejection Distribution**: Ensure fair request distribution
4. **Set Reasonable Max Rejection**: Never block 100% of traffic
5. **Use Thread-Safe Implementation**: For multi-threaded applications
6. **Log Rejections**: Track patterns and user impact
7. **Test Failure Scenarios**: Verify behavior under various error patterns
