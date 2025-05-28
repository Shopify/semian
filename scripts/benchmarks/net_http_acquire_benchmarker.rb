#!/usr/bin/env ruby
# frozen_string_literal: true

# Envronment variable SEMIAN_VERSION have values v0.16.0, HEAD, master, custom-branch-name.
target_version = ENV.fetch("SEMIAN_VERSION", nil)
if target_version.nil? && !ARGV.empty?
  target_version = ARGV.first.sub("SEMIAN_VERSION=", "")
end

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "benchmark-ips", require: "benchmark/ips"
  gem "benchmark-memory", require: "benchmark/memory"
  if target_version
    gem "semian", git: "https://github.com/shopify/semian.git", ref: target_version
  end
end

require "socket"
require "net/http"
require "benchmark/ips"

def server(server_port)
  fork do
    trap("TERM") do
      puts "Server: kill signal received...shutting down"
      exit
    end
    # We need to include the Content-Type and Content-Length headers
    # to let the client know the size and type of data
    # contained in the response. Note that HTTP is whitespace
    # sensitive, and expects each header line to end with CRLF (i.e. "\r\n")
    response = "success!"
    response_headers_basis =
      "HTTP/1.1 200 OK\r\n" \
        "Content-Type: text/plain\r\n" \
        "Content-Length: #{response.bytesize}\r\n" \
        "Connection: close\r\n\r\n#{response}"

    server = TCPServer.new("127.0.0.1", server_port)
    puts "Server: started on #{server_port}..."
    loop do
      Thread.start(server.accept) do |socket|
        # NOTICE: Ignore for now the request!
        # request = socket.gets
        socket.print(response_headers_basis)
        socket.close
      end
    end
  end
end

# Benchmarking
class GCSuite
  def warming(*)
    run_gc
  end

  def warmup_stats(*)
  end

  def add_report(*)
  end

  private

  def run_gc
    GC.enable
    GC.start
    GC.disable
  end
end

def bench(target_version, server_port)
  host = "127.0.0.1"
  suite = GCSuite.new
  report_name = "without HEAD"

  if target_version
    require "semian"
    require "semian/version"
    require "semian/net_http"
    puts "Load Semian #{Semian::VERSION}"
    report_name = "with #{target_version}"

    if ENV.key?("WITH_CIRCUIT_BREAKER_ENABLED")
      puts "Enable Circuit breaker for HTTP requests"
      report_name += "/circuit breaker"
      Semian::NetHTTP.semian_configuration = {
        name: "mock_server",
        circuit_breaker: true,
        success_threshold: 3,
        error_threshold: 2,
        error_timeout: 5,
        bulkhead: true,
        tickets: 1,
      }
    end
  end

  Benchmark.ips do |x|
    x.config(time: 30, warmup: 10, suite: suite)

    x.report(report_name) do
      Net::HTTP.get_response(host, "/", server_port)
    end

    x.save!("benchmarks_latency.json")
    x.compare!
  end

  # NOTICE: The gem is not working properly with 3.2 - it shows the same numbers!
  Benchmark.memory do |x|
    x.report(report_name) do
      Net::HTTP.get_response(host, "/", server_port)
    end
    x.compare!
    x.hold!("benchmarks_memory.json")
  end
end

# Exit
begin
  server_port = 2345
  server_pid = server(server_port)
  sleep(1)
  bench(target_version, server_port)
ensure
  Process.kill(:TERM, server_pid)
end
