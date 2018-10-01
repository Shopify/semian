$LOAD_PATH.unshift File.expand_path('../lib', __FILE__)

require 'semian/version'
require 'semian/platform'

Gem::Specification.new do |s|
  s.name = 'semian'
  s.version = Semian::VERSION
  s.summary = 'Bulkheading for Ruby with SysV semaphores'
  s.description = <<-DOC
    A Ruby C extention that is used to control access to shared resources
    across process boundaries with SysV semaphores.
  DOC
  s.homepage = 'https://github.com/shopify/semian'
  s.authors = ['Scott Francis', 'Simon Eskildsen', 'Dale Hamel']
  s.email = 'scott.francis@shopify.com'
  s.license = 'MIT'

  s.files = Dir['{lib,ext}/**/**/*.{rb,h,c}']
  s.extensions = ['ext/semian/extconf.rb']
  s.add_development_dependency 'rake-compiler', '~> 0.9'
  s.add_development_dependency 'rake', '< 11.0'
  s.add_development_dependency 'timecop'
  s.add_development_dependency 'minitest'
  s.add_development_dependency 'byebug'
  s.add_development_dependency 'mysql2'
  s.add_development_dependency 'redis'
  s.add_development_dependency 'thin', '~> 1.7.2'
  s.add_development_dependency 'toxiproxy', '~> 1.0.0'
  s.add_development_dependency 'grpc'
  s.add_development_dependency 'mocha'
  s.add_development_dependency 'memory_profiler'
  s.add_development_dependency 'benchmark-memory'
end
