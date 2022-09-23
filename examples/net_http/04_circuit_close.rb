# frozen_string_literal: true

require "semian"
require "semian/net_http"
require_relative "../colors"

puts "> Starting example #{__FILE__}".blue.bold
puts
puts "> Initialize print Semian state changes".blue.bold
Semian.subscribe do |event, resource, scope, adapter|
  puts "[semian] adapter=#{adapter} scope=#{scope} event=#{event} " \
    "resource_name=#{resource.name} resource=#{resource}".gray
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
  puts "[semian/http] invoked config for host=#{host}(#{host.class}) port=#{port}(#{port.class})".gray

  if host == "example.com"
    puts "  [semian/http] set resource name example_com with any port".gray
    SEMIAN_PARAMETERS.merge(name: "example_com")
  else
    puts "  [semian/http] skip semian initialization".gray
    nil
  end
end

puts "> Test requests".blue.bold

success_host = URI("http://example.com/index.html")
bad_host = URI("http://example.com:81/index.html")

puts " >> 1. Request to http://example.com/index.html - success".cyan
response = Net::HTTP.get_response(success_host)
puts "  > Response status: #{response.code}"
puts

puts " >> 2. Request to http://example.com:81/index.html - fail".magenta
begin
  Net::HTTP.start("example.com", 81, open_timeout: 3) do |http|
    http.request_get(bad_host)
  end
rescue => e
  puts "   >> Could not connect: #{e.message}".brown
end
puts

puts " >> 3. Request to http://example.com:81/index.html - fail".magenta
begin
  Net::HTTP.start("example.com", 81, open_timeout: 3) do |http|
    http.request_get(bad_host)
  end
rescue => e
  puts "   >> Could not connect: #{e.message}".brown
end
puts "   !!! Semian changed state from `closed` to `open` and record last error exception !!!".red.bold
puts

puts " >> 4. Request to http://example.com:81/index.html - fail".magenta
begin
  Net::HTTP.start("example.com", 81, open_timeout: 3) do |http|
    http.request_get(bad_host)
  end
rescue Net::CircuitOpenError => e
  puts "  >> Semian is open: #{e.message}".brown
end
puts

puts " >> 5. Request to HELTHY http://example.com:/index.html - fail".magenta.bold
begin
  Net::HTTP.start("example.com", 80, open_timeout: 3) do |http|
    http.request_get(success_host)
  end
rescue Net::CircuitOpenError => e
  puts "   >> Semian is open: #{e.message}".brown
  puts "   !!! Semian open and no request made to example.com:80, even it is HEALTHY !!!".red.bold
end
puts

puts " >> Review semian state:".blue
resource = Semian["nethttp_example_com"]
puts "resource_name=#{resource.name} resource=#{resource} " \
  "closed=#{resource.closed?} open=#{resource.open?} " \
  "half_open=#{resource.half_open?}".gray
puts

puts " >> 6. Waiting for error_timeout (#{SEMIAN_PARAMETERS[:error_timeout]} sec)".blue
sleep(SEMIAN_PARAMETERS[:error_timeout])
puts

puts " >> 7. Request to HELTHY http://example.com:/index.html - success".cyan
Net::HTTP.start("example.com", 80, open_timeout: 3) do |http|
  http.request_get(success_host)
end
puts "   !!! Semian changed state from `open` to `half_open` !!!".red.bold
puts

puts " >> 8. Request to HELTHY http://example.com:/index.html - success".cyan
Net::HTTP.start("example.com", 80, open_timeout: 3) do |http|
  http.request_get(success_host)
end
puts "   !!! Semian changed state from `half_open` to `closed` !!!".red.bold
puts

puts "> That's all Folks!".green
