# Semian::Sync - Shared Circuit Breaker Coordination

Enables circuit breaker state to be synchronized across multiple worker processes.
Errors from all workers are aggregated by a central server, and state changes
are broadcast back to all workers.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SERVER PROCESS                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    CircuitBreakerServer                              │    │
│  │  - Listens on Unix socket                                           │    │
│  │  - Accepts connections                                              │    │
│  │  - Runs background tasks (timeout checks, stats)                    │    │
│  │                                                                      │    │
│  │  ┌───────────────────────────────────────────────────────────────┐  │    │
│  │  │              CircuitBreakerController                          │  │    │
│  │  │  - @resources: { name → {state, errors[], thresholds...} }    │  │    │
│  │  │  - @subscribers: { name → [proxy1, proxy2, ...] }             │  │    │
│  │  │  - State machine logic (closed→open→half_open→closed)         │  │    │
│  │  │  - Bound to connections as :circuit_breaker                    │  │    │
│  │  └───────────────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                                     ▲
                                     │ Unix Socket
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            WORKER PROCESS                                    │
│                                                                              │
│  ┌──────────────────────────┐      ┌────────────────────────────────────┐   │
│  │     CircuitBreaker       │      │         Client (module)              │   │
│  │  (user-facing API)       │      │  - @state_cache                     │   │
│  │                          │      │  - @subscriptions                   │   │
│  │  acquire { }             │─────▶│  - @report_queue                    │   │
│  │  mark_failed(error)      │      │                                     │   │
│  │  mark_success            │      │  ┌──────────────────────────────┐  │   │
│  │  request_allowed?        │      │  │      SemianBusClient         │  │   │
│  │                          │      │  │  - Auto-reconnect            │  │   │
│  │  @state (cached locally) │◀─────│  │  - @circuit_breaker (proxy)  │  │   │
│  └──────────────────────────┘      │  │  - @subscriber_proxy         │  │   │
│                                     │  │                              │  │   │
│                                     │  │  ┌────────────────────────┐ │  │   │
│                                     │  │  │ SubscriberController   │ │  │   │
│                                     │  │  │ on_state_change(r, s)  │ │  │   │
│                                     │  │  └────────────────────────┘ │  │   │
│                                     │  └──────────────────────────────┘  │   │
│                                     └────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Class Responsibilities

| Class | File | Purpose |
|-------|------|---------|
| `CircuitBreaker` | circuit_breaker.rb | User-facing API, delegates to Client, caches state locally |
| `Client` | client.rb | Module managing state cache, report queue, delegates to SemianBusClient |
| `SemianBusClient` | client.rb | Owns connection lifecycle (run task, reconnect), holds RPC proxies |
| `SubscriberController` | client.rb | Receives state change callbacks from server |
| `CircuitBreakerController` | server.rb | State machine logic, RPC interface, manages all resources |
| `CircuitBreakerServer` | server.rb | Socket lifecycle, background tasks, owns controller |

## Data Flow

### 1. Resource Registration (startup)

```
CircuitBreaker.new(:mysql)
        │
        ▼
Client.register_resource(:mysql, config)
        │
        ▼ RPC
CircuitBreakerController.register_resource(:mysql, ...)
        │
        ├─► Creates @resources[:mysql] = {state: :closed, errors: [], ...}
        │
        ▼
Returns {registered: true, state: "closed"}
        │
        ▼
Client.subscribe_to_updates(:mysql) { |state| ... }
        │
        ▼ RPC (passes subscriber_proxy)
CircuitBreakerController.subscribe(:mysql, proxy)
        │
        ▼
Stores proxy in @subscribers[:mysql]
```

### 2. Error Reporting (request fails)

```
CircuitBreaker.acquire { raise Error }
        │
        ▼
CircuitBreaker.mark_failed(error)
        │
        ▼
Client.report_error_async(:mysql, timestamp)
        │
        ▼ RPC
CircuitBreakerController.report_error(:mysql, timestamp)
        │
        ├─► Adds to errors[], checks threshold
        │
        ├─► If threshold reached: state = :open
        │
        ▼
notify_subscribers(:mysql, :open)
        │
        ▼ RPC callback to each proxy
SubscriberController.on_state_change("mysql", "open")
        │
        ▼
Client.handle_state_change → updates @state_cache
        │
        ▼
Invokes registered callbacks
        │
        ▼
CircuitBreaker.@state = :open
```

### 3. State Check (before request)

```
CircuitBreaker.acquire { ... }
        │
        ▼
CircuitBreaker.request_allowed?
        │
        ├─► If @state == :open, refresh from server
        │         │
        │         ▼ RPC
        │   Client.get_state(:mysql)
        │         │
        │         ▼
        │   CircuitBreakerController.get_state(:mysql)
        │
        ▼
Returns true if :closed or :half_open
```

### 4. Timeout Transition (background)

```
CircuitBreakerServer background task (every 1s)
        │
        ▼
CircuitBreakerController.check_timeouts
        │
        ├─► For each :open resource where timeout elapsed
        │
        ├─► state = :half_open
        │
        ▼
notify_subscribers(:mysql, :half_open)
        │
        ▼ RPC callback
All connected clients receive state update
```

## Key Concepts

### State Machine (lives on server)

```
closed ──(error_threshold errors)──► open
                                       │
                                       │ (error_timeout elapsed)
                                       ▼
closed ◄──(success_threshold)─── half_open
                                       │
                                       │ (any error)
                                       ▼
                                     open
```

### Why Shared State?

The **state machine lives on the server** (`CircuitBreakerController`). Clients just:
1. Report events (errors/successes)
2. Cache state locally for fast reads
3. Receive broadcasts when state changes

This allows multiple worker processes to share circuit breaker state - if one worker
sees enough errors to trip the threshold, ALL workers' circuits open simultaneously.

### Graceful Degradation

- Workers continue with local state cache if server unavailable
- Reports queued (up to 1000) for later delivery
- Auto-reconnect with exponential backoff
- Subscriptions automatically restored on reconnect

## Usage

### 1. Start the Server

```bash
bundle exec ruby bin/semian_server
```

Or set environment variables:
```bash
SEMIAN_SYNC_SOCKET=/var/run/semian/semian.sock bundle exec ruby bin/semian_server
```

### 2. Configure Clients

```ruby
ENV["SEMIAN_SYNC_ENABLED"] = "1"
ENV["SEMIAN_SYNC_SOCKET"] = "/var/run/semian/semian.sock"

resource = Semian.register(
  :mysql_primary,
  error_threshold: 3,
  error_timeout: 10,
  success_threshold: 2,
  sync_scope: :shared,  # Enables shared circuit breaker
)

resource.acquire do
  # Your code here - errors are automatically reported
end
```

## Files

```
lib/semian/sync/
├── README.md           # This file
├── client.rb           # Client (module), SemianBusClient, SubscriberController
├── server.rb           # CircuitBreakerServer, CircuitBreakerController
└── circuit_breaker.rb  # CircuitBreaker (user-facing API)
```
