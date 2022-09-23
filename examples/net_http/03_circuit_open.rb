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
puts "  Setup single circuit breaker limited to example.com".blue
puts "  and single port 81 (Integer).".blue
puts "  " + "Bulkhead is DISABLED.".blue.underline
Semian::NetHTTP.semian_configuration = proc do |host, port|
  puts "[semian/http] invoked config for host=#{host}(#{host.class}) port=#{port}(#{port.class})".gray

  if host == "example.com" && port == 81
    puts "  [semian/http] set resource name example_com_81".gray
    SEMIAN_PARAMETERS.merge(name: "example_com_81")
  else
    puts "  [semian/http] skip semian initialization".gray
    nil
  end
end

puts "> Test requests".blue.bold

uri = URI("http://example.com:81/index.html")

puts " >> 1. Request to http://example.com:81/index.html - fail".magenta
begin
  Net::HTTP.start("example.com", 81, open_timeout: 3) do |http|
    http.request_get(uri)
  end
rescue => e
  puts "   >> Could not connect: #{e.message}".brown
end
puts

puts " >> 2. Request to http://example.com:81/index.html - fail".magenta
begin
  Net::HTTP.start("example.com", 81, open_timeout: 3) do |http|
    http.request_get(uri)
  end
rescue => e
  puts "   >> Could not connect: #{e.message}".brown
end
puts "   !!! Semian changed state from `closed` to `open` and record last error exception !!!".red.bold
puts

puts " >> Review semian state:".blue
resource = Semian["nethttp_example_com_81"]
puts "resource_name=#{resource.name} resource=#{resource} " \
  "closed=#{resource.closed?} open=#{resource.open?} " \
  "half_open=#{resource.half_open?}".gray
puts

puts " >> 3. Request to http://example.com:81/index.html - fail".magenta
begin
  Net::HTTP.start("example.com", 81, open_timeout: 3) do |http|
    http.request_get(uri)
  end
rescue Net::CircuitOpenError => e
  puts "   >> Semian is open: #{e.message}".brown
  puts "   !!! Semian open and no request made to example.com:81 !!!".red.bold
end
puts

puts " >> 4. Requests to other ports are still working".cyan
response = Net::HTTP.get_response("example.com", "/index.html")
puts "  > Response status: #{response.code}"
puts
puts " >> Review semian state:".blue
resource = Semian["nethttp_example_com_81"]
puts "resource_name=#{resource.name} resource=#{resource} " \
  "closed=#{resource.closed?} open=#{resource.open?} " \
  "half_open=#{resource.half_open?}".gray
puts

puts " >> 5. Waiting for error_timeout (#{SEMIAN_PARAMETERS[:error_timeout]} sec)".blue
sleep(SEMIAN_PARAMETERS[:error_timeout])
puts

puts " >> 6. Try to connect to host and switch back to open circuit".magenta
begin
  Net::HTTP.start("example.com", 81, open_timeout: 3) do |http|
    http.request_get(uri)
  end
rescue => e
  puts "   >> Could not connect: #{e.message}".brown
end
puts "   !!! Semian changed state from `half_open` to `open` again !!!".red.bold
puts

puts "> That's all Folks!".green
