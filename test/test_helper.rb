require 'minitest/autorun'
require 'semian'
require 'semian/mysql2'
require 'semian/redis'
require 'toxiproxy'
require 'timecop'
require 'tempfile'
require 'fileutils'

require 'helpers/background_helper'

Semian.logger = Logger.new(nil)
Toxiproxy.populate(File.expand_path('../helpers/toxiproxy.json', __FILE__))

class MiniTest::Unit::TestCase
  include BackgroundHelper
end
