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

require 'config/semian_config'

Semian.logger = Logger.new(nil)

Toxiproxy.host = URI::HTTP.build(
  host: SemianConfig['toxiproxy_host'],
  port: SemianConfig['toxiproxy_port'],
)

Toxiproxy.populate([
  {
    name: 'semian_test_mysql',
    upstream: "#{SemianConfig['mysql_host']}:#{SemianConfig['mysql_port']}",
    listen: "#{SemianConfig['toxiproxy_host']}:#{SemianConfig['mysql_toxic_port']}",
  },
  {
    name: 'semian_test_redis',
    upstream: "#{SemianConfig['redis_host']}:#{SemianConfig['redis_port']}",
    listen: "#{SemianConfig['toxiproxy_host']}:#{SemianConfig['redis_toxic_port']}",
  },
  {
    name: 'semian_test_net_http',
    upstream: "#{SemianConfig['server_host']}:#{SemianConfig['server_port']}",
    listen: "#{SemianConfig['toxiproxy_host']}:#{SemianConfig['server_toxic_port']}",
  },
])

class Minitest::Test
  include BackgroundHelper
end
