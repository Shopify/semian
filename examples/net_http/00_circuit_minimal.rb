# frozen_string_literal: true

require "semian"
require "semian/net_http"
require_relative "../colors"

puts "> Starting example #{__FILE__}".blue.bold

SEMIAN_PARAMETERS = {
  circuit_breaker: true,
  success_threshold: 1,
  error_threshold: 3,
  error_timeout: 3,
  bulkhead: false,
}.freeze

Semian::NetHTTP.semian_configuration = proc do |host, port|
  if host == "shopify.com" && port == 80
    SEMIAN_PARAMETERS.merge(name: "shopify_com_80")
  end
end

Net::HTTP.get_response("shopify.com", "/index.html")
