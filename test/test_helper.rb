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

Toxiproxy.host = URI::HTTP.build(
  host: Config['toxiproxy']['host'],
  port: Config['toxiproxy']['port']
)

Toxiproxy.populate([
  {
    name: 'semian_test_mysql',
    upstream: "#{Config['mysql']['host']}:#{Config['mysql']['port']}",
    listen: "#{Config['toxiproxy']['host']}:#{Config['mysql']['toxic_port']}",
  },
  {
    name: 'semian_test_redis',
    upstream: "#{Config['redis']['host']}:#{Config['redis']['port']}",
    listen: "#{Config['toxiproxy']['host']}:#{Config['redis']['toxic_port']}",
  },
  {
    name: 'semian_test_net_http',
    upstream: "#{Config['server']['host']}:#{Config['server']['port']}",
    listen: "#{Config['toxiproxy']['host']}:#{Config['server']['toxic_port']}",
  },
])

class Minitest::Test
  include BackgroundHelper
end
