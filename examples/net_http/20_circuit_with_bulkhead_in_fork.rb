# frozen_string_literal: true

require "semian"
require "semian/net_http"
require_relative "../colors"

puts "> Starting example #{__FILE__}".blue.bold
puts "  Example shows that Circuit breaker with bulkhead works in forks.".gray
puts

unless Semian.semaphores_enabled?
  puts "WARN: Skipping the example - current arch does not support semaphores.".brown.bold
  exit
end

puts "> Initialize print Semian state changes".blue.bold
Semian.subscribe do |event, resource, scope, adapter, payload|
  pid = Process.pid
  puts "[pid=#{pid}]   [semian] adapter=#{adapter} " \
    "scope=#{scope} event=#{event} " \
    "resource_name=#{resource.name} resource=#{resource} " \
    "payload=#{payload}".gray
end

pid = Process.pid
SEMIAN_PARAMETERS = {
  circuit_breaker: true,
  success_threshold: 3,
  error_threshold: 2,
  error_timeout: 5,
  bulkhead: true,
  tickets: 1,
}

puts "> Configure Circuit breaker and Bulkhead for Net::HTTP".blue.bold
puts "  Setup single circuit breaker for all example.com requests".blue
puts "  without limitation per port.".blue
Semian::NetHTTP.semian_configuration = proc do |host, port|
  pid = Process.pid
  puts "[pid=#{pid}]   [semian/http] invoked config in for " \
    "host=#{host}(#{host.class}) port=#{port}(#{port.class})".gray

  if host == "example.com"
    puts "[pid=#{pid}]   [semian/http] set resource name example_com with any port".gray
    SEMIAN_PARAMETERS.merge(name: "example_com")
  else
    puts "[pid=#{pid}]   [semian/http] skip semian initialization".gray
    nil
  end
end

puts "> Initialize Circuit breaker reosources".blue.bold
Net::HTTP.start("example.com", 80) do |http|
  bulkhead = http.semian_resource.bulkhead
  circuit_breaker = http.semian_resource.circuit_breaker
  puts "[pid=#{pid}]  [semian/http] http.semian_identifier = #{http.semian_identifier} " \
    "http.semian_resource=#{http.semian_resource} " \
    "http.disabled?=#{http.disabled?} " \
    "closed=#{circuit_breaker.closed?} " \
    "open=#{circuit_breaker.open?} " \
    "half_open=#{circuit_breaker.half_open?} " \
    "count=#{bulkhead.count} " \
    "tickets=#{bulkhead.tickets} " \
    "workers=#{bulkhead.registered_workers}".gray
end
puts

puts "> Test requests in forks".blue.bold

success_host = URI("http://example.com/index.html")
bad_host = URI("http://example.com:81/index.html")

workers = []

workers << fork do
  pid = Process.pid
  puts "[pid=#{pid}] >> 1. Request to http://example.com:81/index.html to use all Tickets - fail".magenta.bold
  puts "[pid=#{pid}]   !!! Semian starting use the single available ticket. No more tickets for next 5 seconds. !!!".red.bold
  puts
  Net::HTTP.start("example.com", 81, open_timeout: 5) do |http|
    http.request_get(bad_host)
  end
rescue Errno::EADDRNOTAVAIL => e
  puts "[pid=#{pid}] Expected networking problem that blocked the last ticket: #{e.class}: #{e.message}".blue
end
puts

sleep 1

begin
  puts "[pid=#{pid}] >> 2. Request to HEALTHY http://example.com/index.html in a separate FORK - fail".magenta.bold
  Net::HTTP.get_response(success_host)
rescue Net::ResourceBusyError => e
  puts "[pid=#{pid}] Out of tickets: #{e.class}: #{e.message}\n    #{e.backtrace.join("\n    ")}".brown
end
puts "[pid=#{pid}] >> Review semian state:".blue
resource = Semian["nethttp_example_com"]
puts "[pid=#{pid}] resource_name=#{resource.name} resource=#{resource} " \
  "closed=#{resource.circuit_breaker.closed?} " \
  "open=#{resource.circuit_breaker.open?} " \
  "half_open=#{resource.circuit_breaker.half_open?} " \
  "count=#{resource.bulkhead.count} " \
  "tickets=#{resource.bulkhead.tickets} " \
  "workers=#{resource.bulkhead.registered_workers}".gray
puts

begin
  puts "[pid=#{pid}] >> 3. Request to HEALTHY http://example.com/index.html in a separate FORK - fail".magenta.bold
  Net::HTTP.get_response(success_host)
rescue Net::ResourceBusyError => e
  puts "[pid=#{pid}] Out of tickets: #{e.class}: #{e.message}\n    #{e.backtrace.join("\n    ")}".brown
end
puts "[pid=#{pid}]  >> Review semian state:".blue
resource = Semian["nethttp_example_com"]
puts "[pid=#{pid}] resource_name=#{resource.name} resource=#{resource} " \
  "closed=#{resource.circuit_breaker.closed?} " \
  "open=#{resource.circuit_breaker.open?} " \
  "half_open=#{resource.circuit_breaker.half_open?} " \
  "count=#{resource.bulkhead.count} " \
  "tickets=#{resource.bulkhead.tickets} " \
  "workers=#{resource.bulkhead.registered_workers}".gray
puts "[pid=#{pid}]   !!! Semian changed state from `closed` to `open` and record last error exception !!!".red.bold
puts

begin
  puts "[pid=#{pid}] >> 4. Request to HEALTHY http://example.com/index.html in a separate FORK - fail".magenta.bold
  Net::HTTP.get_response(success_host)
rescue Net::CircuitOpenError => e
  puts "[pid=#{pid}] Circuit breaker is open: #{e.class}: #{e.message}\n    #{e.backtrace.join("\n    ")}".brown
  puts "[pid=#{pid}]  >> Review semian state:".blue
  resource = Semian["nethttp_example_com"]
  puts "[pid=#{pid}] resource_name=#{resource.name} resource=#{resource} " \
    "closed=#{resource.circuit_breaker.closed?} " \
    "open=#{resource.circuit_breaker.open?} " \
    "half_open=#{resource.circuit_breaker.half_open?} " \
    "count=#{resource.bulkhead.count} " \
    "tickets=#{resource.bulkhead.tickets} " \
    "workers=#{resource.bulkhead.registered_workers}".gray
  puts
end

workers.each do |w|
  Process.waitpid(w)
end

puts "[pid=#{pid}]   !!! Bulkhead got ticket available !!!".red.bold

begin
  puts "[pid=#{pid}] >> 5. Request to HEALTHY http://example.com/index.html - failed".magenta.bold
  Net::HTTP.get_response(success_host)
rescue Net::CircuitOpenError => e
  puts "[pid=#{pid}] Circuit breaker is open: #{e.class}: #{e.message}\n    #{e.backtrace.join("\n    ")}".brown
  puts "[pid=#{pid}]  >> Review semian state:".blue
  resource = Semian["nethttp_example_com"]
  puts "[pid=#{pid}] resource_name=#{resource.name} resource=#{resource} " \
    "closed=#{resource.circuit_breaker.closed?} " \
    "open=#{resource.circuit_breaker.open?} " \
    "half_open=#{resource.circuit_breaker.half_open?} " \
    "count=#{resource.bulkhead.count} " \
    "tickets=#{resource.bulkhead.tickets} " \
    "workers=#{resource.bulkhead.registered_workers}".gray
end
puts "[pid=#{pid}]   !!! Circuit breaker still `open`, because of error_timeout !!!".red.bold
puts

sleep 2

puts "[pid=#{pid}] >> 5. Request to HEALTHY http://example.com/index.html - success".cyan.bold
Net::HTTP.get_response(success_host)
puts "[pid=#{pid}]   !!! Circuit breaker changed state from `open` to `half_open`, because of error_timeout !!!".red.bold
puts

puts "> That's all Folks!".green
