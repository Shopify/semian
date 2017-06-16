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
require 'byebug'

Semian.logger = Logger.new(nil)

TOXIPROXY_HOST = 'toxiproxy'
TOXIPROXY_PORT = 8474
TOXIPROXY_URL = "http://#{TOXIPROXY_HOST}:#{TOXIPROXY_PORT}"

MYSQL_HOST = 'mysql'
MYSQL_PORT = 3306
MYSQL_TOXIC_PORT = 13306

REDIS_HOST = 'redis'
REDIS_PORT = 6379
REDIS_TOXIC_PORT = 16379

NET_HTTP_HOST = 'library'
NET_HTTP_PORT = 31050
NET_HTTP_TOXIC_PORT = 31051

Toxiproxy.host = TOXIPROXY_URL

Toxiproxy.populate([
  {
    name: 'semian_test_mysql',
    upstream: "#{MYSQL_HOST}:#{MYSQL_PORT}",
    listen: "#{TOXIPROXY_HOST}:#{MYSQL_TOXIC_PORT}",
  },
  {
    name: 'semian_test_redis',
    upstream: "#{REDIS_HOST}:#{REDIS_PORT}",
    listen: "#{TOXIPROXY_HOST}:#{REDIS_TOXIC_PORT}",
  },
  {
    name: 'semian_test_net_http',
    upstream: "#{NET_HTTP_HOST}:#{NET_HTTP_PORT}",
    listen: "#{TOXIPROXY_HOST}:#{NET_HTTP_TOXIC_PORT}",
  },
])

class Minitest::Test
  include BackgroundHelper
end
