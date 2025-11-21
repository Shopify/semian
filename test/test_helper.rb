# frozen_string_literal: true

require "rubygems"
require "bundler/setup"

require "minitest/autorun"
$VERBOSE = true
require "semian"
require "toxiproxy"
require "tempfile"
require "fileutils"
require "mocha"
require "mocha/minitest"

require "helpers/adapter_helper"
require "helpers/background_helper"
require "helpers/circuit_breaker_helper"
require "helpers/mock_server.rb"
require "helpers/resource_helper"
require "helpers/time_helper.rb"

require "config/semian_config"

BIND_ADDRESS = "0.0.0.0"

Semian.logger = Logger.new(nil, Logger::FATAL)

Toxiproxy.host = URI::HTTP.build(
  host: SemianConfig["toxiproxy_upstream_host"],
  port: SemianConfig["toxiproxy_upstream_port"],
)

Toxiproxy.populate([
  {
    name: "semian_test_mysql",
    upstream: "#{SemianConfig["mysql_host"]}:#{SemianConfig["mysql_port"]}",
    listen: "#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["mysql_toxiproxy_port"]}",
  },
  {
    name: "semian_test_postgres",
    upstream: "#{SemianConfig["postgres_host"]}:#{SemianConfig["postgres_port"]}",
    listen: "#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["postgres_toxiproxy_port"]}",
  },
  {
    name: "semian_test_redis",
    upstream: "#{SemianConfig["redis_host"]}:#{SemianConfig["redis_port"]}",
    listen: "#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["redis_toxiproxy_port"]}",
  },
  {
    name: "semian_test_net_http",
    upstream: "#{SemianConfig["http_host"]}:#{SemianConfig["http_port_service_a"]}",
    listen: "#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["http_toxiproxy_port"]}",
  },
  {
    name: "semian_test_grpc",
    upstream: "#{SemianConfig["grpc_host"]}:#{SemianConfig["grpc_port"]}",
    listen: "#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["grpc_toxiproxy_port"]}",
  },
])

Toxiproxy.reset

servers = []
servers << MockServer.start(hostname: BIND_ADDRESS, port: SemianConfig["http_port_service_a"])
servers << MockServer.start(hostname: BIND_ADDRESS, port: SemianConfig["http_port_service_b"])

Minitest.after_run do
  servers.each(&:stop)
end

module Minitest
  class Test
    include TimeHelper
    include ResourceHelper
  end
end
