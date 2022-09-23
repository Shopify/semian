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
  error_threshold: 3,
  error_timeout: 5,
  bulkhead: false,
}

puts "> Configure Circuit breaker for Net::HTTP".blue.bold
Semian::NetHTTP.semian_configuration = proc do |host, port|
  puts "[semian/http] invoked config for host=#{host}(#{host.class}) port=#{port}(#{port.class})".gray

  if host == "example.com" && port == 80
    puts "  set resource name example_com_80".gray
    SEMIAN_PARAMETERS.merge(name: "example_com_80")
  else
    puts "  skip semian initialization".gray
    nil
  end
end

puts "> Test that Circuit breaker with `port` as integer".blue.bold
Net::HTTP.start("example.com", 80) do |http|
  puts "[semian/http] http.semian_identifier = #{http.semian_identifier} " \
    "http.semian_resource = #{http.semian_resource} " \
    "http.disabled? = #{http.disabled?}".gray
end
puts

puts "> Test semian state for not matched host and port (port is string)".blue.bold
Net::HTTP.start("example.com", "80") do |http|
  puts "[semian/http] http.disabled? = #{http.disabled?}".gray
end
puts

puts "> Test requests".blue.bold
puts " >> 1. Request to http://example.com/index.html - success".cyan
response = Net::HTTP.get_response("example.com", "/index.html")
puts "  > Response status: #{response.code}"
puts

puts " >> 2. Request to http://example.com/index.json - success".cyan
response = Net::HTTP.get_response("example.com", "/index.json")
puts "  > Response status: #{response.code}"
puts

puts "> Get semian resource by name".blue.bold
resource = Semian["nethttp_example_com_80"]
puts "resource_name=#{resource.name} resource=#{resource} " \
  "closed=#{resource.closed?} open=#{resource.open?} " \
  "half_open=#{resource.half_open?}".gray
puts

puts "> That's all Folks!".green
