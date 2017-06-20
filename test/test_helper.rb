require 'minitest/autorun'
require 'semian'
require 'semian/mysql2'
require 'semian/redis'
require 'toxiproxy'
require 'timecop'
require 'tempfile'
require 'fileutils'

require 'helpers/background_helper'
require 'helpers/circuit_breaker_helper'
require 'helpers/resource_helper'
require 'helpers/adapter_helper'

require 'config/semian_test_config'

Semian.logger = Logger.new(nil)

class ToxiproxyConfig
  include SemianTestConfig::Helpers

  Toxiproxy.host = URI::HTTP.build(
    host: toxiproxy_host,
    port: toxiproxy_port
  )

  Toxiproxy.populate([
    {
      name: 'semian_test_mysql',
      upstream: "#{mysql_host}:#{mysql_port}",
      listen: "#{toxiproxy_host}:#{mysql_toxic_port}",
    },
    {
      name: 'semian_test_redis',
      upstream: "#{redis_host}:#{redis_port}",
      listen: "#{toxiproxy_host}:#{redis_toxic_port}",
    },
    {
      name: 'semian_test_net_http',
      upstream: "#{server_host}:#{server_port}",
      listen: "#{toxiproxy_host}:#{server_toxic_port}",
    },
  ])
end

class Minitest::Test
  include BackgroundHelper
end
