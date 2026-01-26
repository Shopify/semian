# Circuit Breaker Sync Demo

This demo showcases the shared circuit breaker coordination using the `Semian::Sync` module. Circuit breaker state is synchronized across multiple clients via a central server using async-bus for transparent RPC and bidirectional communication.

**Note:** This demo uses async-service to manage the server lifecycle and async-bus for client-server communication.

## Prerequisites

```bash
bundle install
```

## Running the Demo

### 1. Start the Server

In one terminal:

```bash
bundle exec async-service examples/circuit_breaker_sync/demo_server.rb
```

The server will:
- Listen on `/tmp/semian_demo.sock`
- Manage a single circuit breaker with default config (3 errors to open, 10s timeout, 2 successes to close)
- Log state transitions and client connections

### 2. Start Client(s)

#### Interactive Mode

Open separate terminals for each client:

```bash
# Client 1
bundle exec ruby examples/circuit_breaker_sync/demo_client.rb client1

# Client 2
bundle exec ruby examples/circuit_breaker_sync/demo_client.rb client2
```

Interactive commands:
- `e` - Simulate an error (triggers circuit breaker)
- `s` - Simulate a success
- `a` - Attempt acquire (will raise if open)
- `?` - Get current state
- `q` - Quit

#### Automated Mode

Run an automated demo that triggers circuit state changes:

```bash
bundle exec ruby examples/circuit_breaker_sync/demo_client.rb client1 auto
```

The automated demo will:
1. Report 3 errors to open the circuit
2. Wait 11 seconds for timeout
3. Report 2 successes to close the circuit

## Expected Output

### Server Terminal

```
0.0s     info: SemianSyncService [oid=0x...] [ec=0x...] [pid=12345]
               | Semian Sync Server listening on /tmp/semian_demo.sock
0.01s    info: SemianSyncService [oid=0x...] [ec=0x...] [pid=12345]
               | Client connected
```

### Client Terminal (Interactive)

```
============================================================
Semian Circuit Breaker Sync Demo Client
============================================================

Socket: /tmp/semian_demo.sock
Resource: demo_resource

Mode: Interactive (use 'auto' argument for automated demo)

[client1] Registering resource with sync_scope: :shared...
[client1] Resource registered!
[client1] Circuit breaker type: Semian::Sync::CircuitBreaker
[client1] Current state: closed

[client1] Commands:
  e - Simulate an error (triggers circuit breaker)
  s - Simulate a success
  a - Attempt acquire (will raise if open)
  ? - Get current state
  q - Quit

[client1] > e
[client1] Error reported. State: closed
[client1] > e
[client1] Error reported. State: closed
[client1] > e
[client1] Error reported. State: open
```

### Client Terminal (Automated)

```
============================================================
Semian Circuit Breaker Sync Demo Client
============================================================

Socket: /tmp/semian_demo.sock
Resource: demo_resource

Mode: Automated demo

[client1] Registering resource with sync_scope: :shared...
[client1] Resource registered!
[client1] Circuit breaker type: Semian::Sync::CircuitBreaker
[client1] Initial state: closed

[client1] Starting automated demo...
[client1] Will report 3 errors to open circuit, wait for half-open, then close it

[client1] Reporting error 1/3...
[client1] State after error: closed
[client1] Reporting error 2/3...
[client1] State after error: closed
[client1] Reporting error 3/3...
[client1] State after error: open

[client1] Circuit should be OPEN now. Waiting 11 seconds for timeout...
[client1] State after timeout: half_open

[client1] Reporting successes to close circuit...
[client1] Reporting success 1/2...
[client1] State after success: half_open
[client1] Reporting success 2/2...
[client1] State after success: closed

[client1] Demo complete!
```

## Multi-Client Demo

To see state synchronization across multiple clients:

1. Start the server
2. Start two clients in interactive mode (`client1` and `client2`)
3. Report errors from `client1` to open the circuit
4. Observe that `client2` also sees the open state

## Architecture

### Using the Real Semian API

The demo client uses the standard Semian API with `sync_scope: :shared`:

```ruby
ENV["SEMIAN_SYNC_ENABLED"] = "1"
ENV["SEMIAN_SYNC_SOCKET"] = "/tmp/semian_demo.sock"

resource = Semian.register(
  :my_resource,
  error_threshold: 3,
  error_timeout: 10,
  success_threshold: 2,
  exceptions: [MyError],
  sync_scope: :shared,  # This enables shared circuit breaker
)

resource.acquire do
  # Your code here - errors are automatically reported
end
```

### Async-Bus Communication

```
┌─────────────────┐          ┌─────────────────────────────────┐
│  Demo Client    │          │      async-service              │
│                 │          │  ┌─────────────────────────────┐│
│ ┌─────────────┐ │  socket  │  │    SemianSyncService        ││
│ │ Subscriber  │◄├──────────┼──┤                             ││
│ │ Controller  │ │ callback │  │  ┌───────────────────────┐  ││
│ └─────────────┘ │          │  │  │ CircuitBreakerController│ ││
│                 │          │  │  │                       │  ││
│  circuit_breaker├──────────┼──┤  │  - state transitions  │  ││
│      proxy      │   RPC    │  │  │  - error/success track│  ││
│                 │          │  │  │  - subscriber mgmt    │  ││
└─────────────────┘          │  │  └───────────────────────┘  ││
                             │  └─────────────────────────────┘│
                             └─────────────────────────────────┘
```

### Key Patterns Demonstrated

1. **Real Semian API**: Uses `Semian.register(..., sync_scope: :shared)` for shared circuit breakers
2. **async-service**: Manages server lifecycle with health checking and graceful shutdown
3. **Controller Binding**: Server binds `CircuitBreakerController` for client access
4. **Transparent RPC**: Client calls methods on proxy as if they were local
5. **Bidirectional Communication**: Client binds `SubscriberController`, server calls back via proxy
6. **State Machine**: closed -> open -> half_open -> closed

### Code Structure

- `demo_server.rb`: async-service configuration with `SemianSyncService`
- `demo_client.rb`: Uses real Semian API with `sync_scope: :shared`

## What This Validates

- Semian.register with sync_scope: :shared creates a `Semian::Sync::CircuitBreaker`
- async-service manages server lifecycle properly
- async-bus server accepts multiple concurrent connections
- Transparent RPC for circuit breaker operations
- Bidirectional communication via subscriber callbacks
- State change broadcasts to all subscribed clients
- Circuit breaker state machine works correctly
- Dead subscriber cleanup on notification failure
- Client auto-reconnect with queue flushing and resubscription
