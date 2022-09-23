# frozen_string_literal: true

require "semian"
require "semian/net_http"
require_relative "../colors"

puts "> Starting example #{__FILE__}".blue.bold
puts "  Example shows that Circuit breaker share the state between Threads.".gray
puts
puts "> Initialize print Semian state changes".blue.bold
Semian.subscribe do |event, resource, scope, adapter, payload|
  pid = Process.pid
  puts "[pid=#{pid}]   [semian] adapter=#{adapter} " \
    "scope=#{scope} event=#{event} " \
    "resource_name=#{resource.name} resource=#{resource} " \
    "payload=#{payload}".gray
end

SEMIAN_PARAMETERS = {
  circuit_breaker: true,
  success_threshold: 3,
  error_threshold: 2,
  error_timeout: 5,
  bulkhead: false,
}

puts "> Configure Circuit breaker for Net::HTTP".blue.bold
puts "  Setup single circuit breaker for all example.com requests".blue
puts "  without limitation per port.".blue
puts "  " + "Bulkhead is DISABLED.".blue.underline
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
  puts "[semian/http] http.semian_identifier = #{http.semian_identifier} " \
    "http.semian_resource = #{http.semian_resource} " \
    "http.disabled? = #{http.disabled?}".gray
end
puts

puts "> Test requests in forks".blue.bold

success_host = URI("http://example.com/index.html")
bad_host = URI("http://example.com:81/index.html")

worker_foo = fork do
  pid = Process.pid
  puts "[pid=#{pid}] >> 1. Request to http://example.com/index.html - success".cyan
  response = Net::HTTP.get_response(success_host)
  puts "[pid=#{pid}]   > Response status: #{response.code}"
  puts
  sleep(4)
  puts "[pid=#{pid}] >> 3. Request to http://example.com/index.html - success".cyan
  response = Net::HTTP.get_response(success_host)
  puts "[pid=#{pid}]   > Response status: #{response.code}"
  puts
  sleep(5)
  puts "[pid=#{pid}] >> 6. Request to HEALTHY http://example.com/index.html in separate FORK - success".cyan.bold
  response = Net::HTTP.get_response(success_host)
  puts "[pid=#{pid}]   > Response status: #{response.code}"
  puts

  puts "[pid=#{pid}] >> Review semian state:".blue
  resource = Semian["nethttp_example_com"]
  puts "[pid=#{pid}]  resource_name=#{resource.name} resource=#{resource} " \
    "closed=#{resource.closed?} open=#{resource.open?} " \
    "half_open=#{resource.half_open?}".gray
  puts
end

worker_bar = fork do
  pid = Process.pid
  sleep(1)
  puts "[pid=#{pid}] >> 2. Request to http://example.com:81/index.html - fail".magenta
  begin
    Net::HTTP.start("example.com", 81, open_timeout: 3) do |http|
      http.request_get(bad_host)
    end
  rescue => e
    puts "[pid=#{pid}]   >> Could not connect: #{e.message}".brown
  end
  puts

  sleep(2)

  puts "[pid=#{pid}] >> 4. Request to http://example.com:81/index.html - fail".magenta
  begin
    Net::HTTP.start("example.com", 81, open_timeout: 3) do |http|
      http.request_get(bad_host)
    end
  rescue => e
    puts "[pid=#{pid}]   >> Could not connect: #{e.message}".brown
  end
  puts "[pid=#{pid}]   !!! Semian changed state from `closed` to `open` and record last error exception !!!".red.bold
  puts

  puts "[pid=#{pid}] >> 5. Request to http://example.com:81/index.html - fail".magenta
  begin
    Net::HTTP.start("example.com", 81, open_timeout: 3) do |http|
      http.request_get(bad_host)
    end
  rescue Net::CircuitOpenError => e
    puts "[pid=#{pid}]  >> Semian is open: #{e.message}".brown
  end
  puts

  puts "[pid=#{pid}] >> Review semian state:".blue
  resource = Semian["nethttp_example_com"]
  puts "[pid=#{pid}]  resource_name=#{resource.name} resource=#{resource} " \
    "closed=#{resource.closed?} open=#{resource.open?} " \
    "half_open=#{resource.half_open?}".gray
  puts
end

Process.waitpid(worker_bar)
Process.waitpid(worker_foo)

puts "> That's all Folks!".green
