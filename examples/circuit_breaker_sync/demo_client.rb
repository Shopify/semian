# frozen_string_literal: true

# Demo client for Circuit Breaker Sync using the real Semian API
# Run: bundle exec ruby examples/circuit_breaker_sync/demo_client.rb [client_name] [mode]
#
# This demo validates:
# - Semian.register with sync_scope: :shared creates a synced circuit breaker
# - The circuit breaker reports errors/successes to the server
# - State change notifications are received from the server
# - Multiple clients see synchronized state

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "semian"

Semian.logger = Logger.new($stdout)
Semian.logger.level = Logger::INFO

SOCKET_PATH = "/tmp/semian_demo.sock"
RESOURCE_NAME = :demo_resource

# Set up environment for sync
ENV["SEMIAN_SYNC_ENABLED"] = "1"
ENV["SEMIAN_SYNC_SOCKET"] = SOCKET_PATH

# Custom error class for demo
class DemoError < StandardError
  def marks_semian_circuits?
    true
  end
end

# Interactive demo client using real Semian API
class DemoClient
  def initialize(name)
    @name = name
    @resource = nil
  end

  def start
    puts "[#{@name}] Registering resource with sync_scope: :shared..."

    # Register a synced circuit breaker using the real Semian API
    @resource = Semian.register(
      RESOURCE_NAME,
      bulkhead: false, # Disable bulkhead for demo simplicity
      error_threshold: 3,
      error_timeout: 10,
      success_threshold: 2,
      exceptions: [DemoError],
      sync_scope: :shared,
    )

    puts "[#{@name}] Resource registered!"
    puts "[#{@name}] Circuit breaker type: #{@resource.circuit_breaker.class}"
    puts "[#{@name}] Current state: #{@resource.circuit_breaker.state.value}"
    puts ""

    # Run interactive loop
    interactive_loop
  rescue Errno::ENOENT
    puts "[#{@name}] Error: Server socket not found at #{SOCKET_PATH}"
    puts "[#{@name}] Make sure the server is running first:"
    puts "  bundle exec async-service examples/circuit_breaker_sync/demo_server.rb"
  rescue Errno::ECONNREFUSED
    puts "[#{@name}] Error: Connection refused"
  rescue => e
    puts "[#{@name}] Error: #{e.class} - #{e.message}"
    puts e.backtrace.first(5).join("\n")
  ensure
    Semian.destroy(RESOURCE_NAME) if @resource
  end

  private

  def interactive_loop
    puts "[#{@name}] Commands:"
    puts "  e - Simulate an error (triggers circuit breaker)"
    puts "  s - Simulate a success"
    puts "  a - Attempt acquire (will raise if open)"
    puts "  ? - Get current state"
    puts "  q - Quit"
    puts ""

    loop do
      print "[#{@name}] > "
      input = $stdin.gets&.strip&.downcase

      case input
      when "e"
        simulate_error
      when "s"
        simulate_success
      when "a"
        attempt_acquire
      when "?"
        show_state
      when "q", nil
        puts "[#{@name}] Goodbye!"
        exit(0)
      else
        puts "[#{@name}] Unknown command. Use e/s/a/?/q"
      end
    rescue => e
      puts "[#{@name}] Command error: #{e.message}"
    end
  end

  def simulate_error
    @resource.acquire do
      raise DemoError, "Simulated error"
    end
  rescue DemoError
    puts "[#{@name}] Error reported. State: #{@resource.circuit_breaker.state.value}"
  rescue Semian::OpenCircuitError
    puts "[#{@name}] Circuit is OPEN - request blocked"
  end

  def simulate_success
    @resource.acquire do
      # Success - do nothing
    end
    puts "[#{@name}] Success reported. State: #{@resource.circuit_breaker.state.value}"
  rescue Semian::OpenCircuitError
    puts "[#{@name}] Circuit is OPEN - cannot report success"
  end

  def attempt_acquire
    @resource.acquire do
      puts "[#{@name}] Acquire succeeded!"
    end
  rescue Semian::OpenCircuitError
    puts "[#{@name}] Circuit is OPEN - acquire blocked"
  end

  def show_state
    puts "[#{@name}] Current state: #{@resource.circuit_breaker.state.value}"
  end
end

# Automated demo that triggers circuit state changes
class AutomatedDemoClient
  def initialize(name)
    @name = name
    @resource = nil
  end

  def start
    puts "[#{@name}] Registering resource with sync_scope: :shared..."

    # Register a synced circuit breaker using the real Semian API
    @resource = Semian.register(
      RESOURCE_NAME,
      bulkhead: false,
      error_threshold: 3,
      error_timeout: 10,
      success_threshold: 2,
      exceptions: [DemoError],
      sync_scope: :shared,
    )

    puts "[#{@name}] Resource registered!"
    puts "[#{@name}] Circuit breaker type: #{@resource.circuit_breaker.class}"
    puts "[#{@name}] Initial state: #{@resource.circuit_breaker.state.value}"
    puts ""

    # Demo sequence
    puts "[#{@name}] Starting automated demo..."
    puts "[#{@name}] Will report 3 errors to open circuit, wait for half-open, then close it"
    puts ""

    # Report errors to open the circuit
    3.times do |i|
      sleep(1)
      puts "[#{@name}] Reporting error #{i + 1}/3..."
      begin
        @resource.acquire { raise DemoError, "Error #{i + 1}" }
      rescue DemoError
        # Expected
      rescue Semian::OpenCircuitError
        puts "[#{@name}] Circuit already open!"
      end
      puts "[#{@name}] State after error: #{@resource.circuit_breaker.state.value}"
    end

    puts ""
    puts "[#{@name}] Circuit should be OPEN now. Waiting 11 seconds for timeout..."
    sleep(11)

    # Refresh state from server
    puts "[#{@name}] State after timeout: #{@resource.circuit_breaker.state.value}"
    puts ""

    # Report successes to close the circuit
    puts "[#{@name}] Reporting successes to close circuit..."
    2.times do |i|
      sleep(1)
      puts "[#{@name}] Reporting success #{i + 1}/2..."
      begin
        @resource.acquire { } # Success
      rescue Semian::OpenCircuitError
        puts "[#{@name}] Circuit still open, cannot report success"
      end
      puts "[#{@name}] State after success: #{@resource.circuit_breaker.state.value}"
    end

    puts ""
    puts "[#{@name}] Demo complete!"

    # Keep alive for a bit
    sleep(2)
  rescue Errno::ENOENT
    puts "[#{@name}] Error: Server not running. Start it first:"
    puts "  bundle exec async-service examples/circuit_breaker_sync/demo_server.rb"
  rescue => e
    puts "[#{@name}] Error: #{e.class} - #{e.message}"
    puts e.backtrace.first(5).join("\n")
  ensure
    Semian.destroy(RESOURCE_NAME) if @resource
  end
end

# Run the client
if __FILE__ == $PROGRAM_NAME
  require "async"

  # Parse arguments: support both "auto" and "client_name auto"
  if ARGV[0] == "auto"
    mode = "auto"
    client_name = ARGV[1] || "client-#{Process.pid}"
  else
    client_name = ARGV[0] || "client-#{Process.pid}"
    mode = ARGV[1]
  end

  puts "=" * 60
  puts "Semian Circuit Breaker Sync Demo Client"
  puts "=" * 60
  puts ""
  puts "Socket: #{SOCKET_PATH}"
  puts "Resource: #{RESOURCE_NAME}"
  puts ""

  if mode == "auto"
    puts "Mode: Automated demo"
    puts ""
    client = AutomatedDemoClient.new(client_name)
  else
    puts "Mode: Interactive (use 'auto' argument for automated demo)"
    puts ""
    client = DemoClient.new(client_name)
  end

  # Run inside Async reactor to keep async-bus connection alive
  Async do
    client.start
  end
end
