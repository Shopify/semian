require 'minitest/autorun'
require 'semian'
require 'semian/mysql2'
require 'toxiproxy'
require 'timecop'
require 'tempfile'
require 'fileutils'

Semian.logger = Logger.new(nil)
Toxiproxy.populate(File.expand_path('../fixtures/toxiproxy.json', __FILE__))
