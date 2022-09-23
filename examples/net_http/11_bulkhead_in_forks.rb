# frozen_string_literal: true

require "semian"
require "semian/net_http"
require_relative "../colors"

puts "> Starting example #{__FILE__}".blue.bold
puts "  Example shows that Bulkhead blocks concurent requests, while there is no free tickets available.".gray
puts
puts "> Initialize print Semian state changes".blue.bold
Semian.subscribe do |event, resource, scope, adapter|
  pid = Process.pid
  puts "[pid=#{pid}][semian] adapter=#{adapter} scope=#{scope} event=#{event} " \
    "resource_name=#{resource.name} resource=#{resource}".gray
end

SEMIAN_PARAMETERS = {
  bulkhead: true,
  tickets: 1,            # Number of concurent connections.
  timeout: 1,            # Timeout in seconds (1 sec) to wait to get a free ticket.
  circuit_breaker: false,
}

Semian::NetHTTP.semian_configuration = proc do |host, port|
  pid = Process.pid
  puts "[pid=#{pid}][semian/http] invoked config for host=#{host}(#{host.class}) port=#{port}(#{port.class})".gray

  if host == "example.com"
    SEMIAN_PARAMETERS.merge(name: "example_com")
  end
end

puts "> Test requests in forks".blue.bold

pid = Process.pid
puts "[pid=#{pid}] >> Request to http://example.com:80/index.html - success".cyan.bold
uri = URI("http://example.com:80/index.html")
Net::HTTP.get_response(uri)

workers = []

workers << fork do
  pid = Process.pid
  puts "[pid=#{pid}] >> Request to http://example.com:81/index.html to use all Tickets - fail".magenta.bold
  puts "[pid=#{pid}]   !!! Semian starting use the single available ticket. No more tickets for next 5 seconds. !!!".red.bold
  puts
  Net::HTTP.start("example.com", 81, open_timeout: 5) do |http|
    http.request_get(bad_host)
  end
rescue Errno::EADDRNOTAVAIL => e
  puts "[pid=#{pid}] Expected networking problem that blocked the last ticket: #{e.class}: #{e.message}".blue
end

2.times do
  workers << fork do
    pid = Process.pid
    puts "[pid=#{pid}] >> Request to HEALTHY http://example.com/index.html in a separate FORK - fail".magenta.bold
    Net::HTTP.get_response(uri)
    raise "Should not get to this line."
  rescue Net::ResourceBusyError => e
    puts "[pid=#{pid}] Out of tickets: #{e.class}: #{e.message}\n    #{e.backtrace.join("\n    ")}".brown
  end
end

workers.each do |w|
  Process.waitpid(w)
end

puts "[pid=#{pid}] >> Request to HEALTHY http://example.com:80/index.html - success".cyan.bold
uri = URI("http://example.com:80/index.html")
Net::HTTP.get_response(uri)

puts "> That's all Folks!".green
