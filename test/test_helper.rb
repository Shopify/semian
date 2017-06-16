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

require 'config/config'

Semian.logger = Logger.new(nil)

TOXIPROXY_HOST = 'toxiproxy'
TOXIPROXY_PORT = 8474
TOXIPROXY_URL = "http://#{TOXIPROXY_HOST}:#{TOXIPROXY_PORT}"

REDIS_HOST = 'redis'
REDIS_PORT = 6379
REDIS_TOXIC_PORT = 16379

NET_HTTP_HOST = 'library'
NET_HTTP_PORT = 31050
NET_HTTP_TOXIC_PORT = 31051

Toxiproxy.host = URI::HTTP.build(
  host: Config.host_for('toxiproxy'),
  port: Config.port_for('toxiproxy')
)

Toxiproxy.populate([
  {
    name: 'semian_test_mysql',
    upstream: "#{Config.host_for('mysql')}:#{Config.port_for('mysql')}",
    listen: "#{Config.host_for('toxiproxy')}:#{Config.toxic_port_for('mysql')}",
  },
  {
    name: 'semian_test_redis',
    upstream: "#{Config.host_for('redis')}:#{Config.port_for('redis')}",
    listen: "#{Config.host_for('toxiproxy')}:#{Config.toxic_port_for('redis')}",
  },
  {
    name: 'semian_test_net_http',
    upstream: "#{Config.host_for('library')}:#{Config.port_for('library')}",
    listen: "#{Config.host_for('toxiproxy')}:#{Config.toxic_port_for('library')}",
  },
])

class Minitest::Test
  include BackgroundHelper
end
