# frozen_string_literal: true

require "semian"
require "semian/net_http"
require_relative "../colors"

puts "> Starting example #{__FILE__}".blue.bold

SEMIAN_PARAMETERS = {
  bulkhead: true,
  tickets: 1,  # Number of concurent connections
  timeout: 3,  # Wait for the next available ticket
  circuit_breaker: false,
}.freeze

Semian::NetHTTP.semian_configuration = proc do |host, port|
  if host == "example.com" && port == 80
    SEMIAN_PARAMETERS.merge(name: "example_com_80")
  end
end

response = Net::HTTP.get_response("example.com", "/index.html")
puts "Response: #{response.code}"
