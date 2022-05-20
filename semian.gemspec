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

  s.metadata['allowed_push_host'] = 'https://rubygems.org'

  s.files = Dir['{lib,ext}/**/**/*.{rb,h,c}']
  s.extensions = ['ext/semian/extconf.rb']
end
