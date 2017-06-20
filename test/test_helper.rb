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

require 'mkmf'
def network_host
  return "192.168.64.96" if File.exists?("/opt/dev/dev.sh")
  "127.0.0.1"
end

Semian.logger = Logger.new(nil)
Toxiproxy.host = "http://#{network_host}:8474"
Toxiproxy.populate([
  {
    name: 'semian_test_mysql',
    upstream: "#{network_host}:3306",
    listen: "#{network_host}:13306",
  },
  {
    name: 'semian_test_redis',
    upstream: "#{network_host}:6379",
    listen: "#{network_host}:16379",
  },
  {
    name: 'semian_test_net_http',
    upstream: "#{network_host}:31050",
    listen: "#{network_host}:31051",
  },
])

class Minitest::Test
  include BackgroundHelper
end
