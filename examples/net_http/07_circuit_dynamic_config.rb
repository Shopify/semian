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
  error_threshold: 1,
  error_timeout: 5,
  bulkhead: false,
  dynamic: true,
  open_circuit_server_errors: true,
}.freeze

uri = URI("http://shopify.com:80")

puts "> Configure Circuit breaker for Net::HTTP".blue.bold
Semian::NetHTTP.semian_configuration = proc do |host, port|
  puts "[semian/http] invoked config for host=#{host}(#{host.class}) port=#{port}(#{port.class})".gray

  if host == "shopify.com"
    puts "  set resource name shopify_com".gray
    sub_resource_name = Thread.current[:current_semian_sub_resource_name]
    # We purposefully do not use the port as the resource name, so that we can
    # force the circuit to open by sending a request to an invalid port, e.g. 81
    SEMIAN_PARAMETERS.merge(name: "shopify_com_#{sub_resource_name}")
  else
    puts "  skip semian initialization".gray
    nil
  end
end

puts "> Test requests".blue.bold
puts " >> 1. Request to http://shopify.com - success".cyan
Thread.current[:current_semian_sub_resource_name] = "sub_resource_1"
response = Net::HTTP.get_response(uri)
puts "  > Response status: #{response.code}"
puts

puts " >> 2. Request to http://shopify.com - success".cyan
Thread.current[:current_semian_sub_resource_name] = "sub_resource_2"
response = Net::HTTP.get_response(uri)
puts "  > Response status: #{response.code}"
puts

puts "> Review semian state:".blue.bold
resource1 = Semian["nethttp_shopify_com_sub_resource_1"]
puts "resource_name=#{resource1.name} resource=#{resource1} " \
  "closed=#{resource1.closed?} open=#{resource1.open?} " \
  "half_open=#{resource1.half_open?}".gray
resource2 = Semian["nethttp_shopify_com_sub_resource_2"]
puts "resource_name=#{resource2.name} resource=#{resource2} " \
  "closed=#{resource2.closed?} open=#{resource2.open?} " \
  "half_open=#{resource2.half_open?}".gray
puts

puts "> Test request errors".blue.bold
puts " >> 3. Request to http://shopify.com - fail".magenta
Thread.current[:current_semian_sub_resource_name] = "sub_resource_1"
begin
  # We use a different port to make the connection fail
  Net::HTTP.start(uri.host, 81, open_timeout: 1) do |http|
    http.request_get(uri)
  end
rescue => e
  puts "   >> Could not connect: #{e.message}".brown
  puts
end

puts " >> 4. Request to http://shopify.com - success".cyan
Thread.current[:current_semian_sub_resource_name] = "sub_resource_2"
response = Net::HTTP.get_response(uri)
puts "  > Response status: #{response.code}"
puts

puts "> Review semian state:".blue.bold
resource1 = Semian["nethttp_shopify_com_sub_resource_1"]
puts "resource_name=#{resource1.name} resource=#{resource1} " \
  "closed=#{resource1.closed?} open=#{resource1.open?} " \
  "half_open=#{resource1.half_open?}".gray
resource2 = Semian["nethttp_shopify_com_sub_resource_2"]
puts "resource_name=#{resource2.name} resource=#{resource2} " \
  "closed=#{resource2.closed?} open=#{resource2.open?} " \
  "half_open=#{resource2.half_open?}".gray
puts

puts " >> 5. Request to http://shopify.com - fail".magenta
begin
  Thread.current[:current_semian_sub_resource_name] = "sub_resource_1"
  Net::HTTP.get_response(uri)
rescue Net::CircuitOpenError => e
  puts "   >> Semian is open: #{e.message}".brown
  puts "   !!! Semian open for sub_resource_1 and no request made to shopify.com:80 !!!".red.bold
end
puts

puts " >> 6. Request to http://shopify.com - success".cyan
Thread.current[:current_semian_sub_resource_name] = "sub_resource_2"
response = Net::HTTP.get_response(uri)
puts "  > Response status: #{response.code}"
puts

puts "> That's all Folks!".green
