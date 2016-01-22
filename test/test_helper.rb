require 'minitest/autorun'
require 'semian'
require 'semian/mysql2'
require 'semian/redis'
require 'toxiproxy'
require 'timecop'
require 'tempfile'
require 'fileutils'
require 'yaml'

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
  {
    name: 'semian_test_net_http',
    upstream: 'localhost:31050',
    listen: 'localhost:31051',
  },
])

def mysql_config
  defaults = {
    username: ENV['USER'],
    host: '127.0.0.1',
    port: '13306',
  }
  defaults.merge(user_config['mysql2'])
end

def user_config
  Hash.new({})
    .merge(File.exist?(Dir.pwd + '/test/test_config.yml') ? YAML.load_file(Dir.pwd + '/test/test_config.yml') : {})
end

class MiniTest::Unit::TestCase
  include BackgroundHelper
end
