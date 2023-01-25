#!/usr/bin/env ruby

# frozen_string_literal: true

# Envronment variable SEMIAN_VERSION have values v0.16.0, HEAD, master, custom-branch-name.
target_version = ENV.fetch("SEMIAN_VERSION", nil)

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "ruby-prof-flamegraph", require: "ruby-prof-flamegraph"
  if target_version
    gem "semian", git: "https://github.com/shopify/semian.git", ref: target_version
  end
end

require "socket"
require "net/http"
require "ruby-prof"
require "ruby-prof-flamegraph"

def server(server_port)
  fork do
    trap("TERM") do
      $stderr.puts "Server: kill signal received...shutting down"
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
    $stderr.puts "Server: started on #{server_port}..."
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

def bench(target_version, server_port)
  host = "127.0.0.1"

  if target_version
    require "semian"
    require "semian/version"
    require "semian/net_http"
    $stderr.puts "Load Semian #{Semian::VERSION}"

    if ENV.key?("WITH_CIRCUIT_BREAKER_ENABLED")
      $stderr.puts "Enable Circuit breaker for HTTP requests"
      Semian::NetHTTP.semian_configuration = proc do
        {
          name: "mock_server",
          circuit_breaker: true,
          success_threshold: 3,
          error_threshold: 2,
          error_timeout: 5,
          bulkhead: true,
          tickets: 1,
        }
      end

      # Semian.subscribe do |event, resource, scope, adapter|
      #   $stderr.puts "[semian] adapter=#{adapter} scope=#{scope} event=#{event} " \
      #     "resource_name=#{resource.name} resource=#{resource}"
      # end
    end
  end

  # http = Net::HTTP.new(host, server_port)
  # warmup
  100.times do
    http = Net::HTTP.new(host, server_port)
    http.open_timeout = 1
    begin
      http.get("/")
    rescue
      nil
    end
  end

  # Profile the code
  result = RubyProf.profile do
    1000.times do
      http = Net::HTTP.new(host, server_port)
      http.open_timeout = 1
      begin
        http.get("/")
      rescue
        nil
      end
    end
  end

  # Print a graph profile to text
  printer = RubyProf::FlameGraphPrinter.new(result)
  printer.print($stdout, {})
end

begin
  server_port = 2345
  server_pid = server(server_port)
  sleep(1)
  bench(target_version, server_port)
ensure
  Process.kill(:TERM, server_pid)
end
