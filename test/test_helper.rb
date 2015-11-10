require 'minitest/autorun'
require 'semian'
require 'semian/mysql2'
require 'semian/redis'
require 'toxiproxy'
require 'timecop'
require 'tempfile'
require 'fileutils'
require 'timeout'

require 'helpers/background_helper'

Semian.logger = Logger.new(nil)
Toxiproxy.populate([
  {
    name: 'semian_test_mysql',
    upstream: 'localhost:3306',
    listen: 'localhost:13306',
  },
  {
    name: 'semian_test_redis',
    upstream: 'localhost:6379',
    listen: 'localhost:16379',
  },
])

class MiniTest::Unit::TestCase
  include BackgroundHelper
end
