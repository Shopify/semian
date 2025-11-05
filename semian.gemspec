# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __FILE__))

require "semian/version"
require "semian/platform"

Gem::Specification.new do |s|
  s.name = "semian"
  s.version = Semian::VERSION
  s.summary = "Bulkheading for Ruby with SysV semaphores"
  s.description = <<-DOC
    A Ruby C extention that is used to control access to shared resources
    across process boundaries with SysV semaphores.
  DOC
  s.homepage = "https://github.com/shopify/semian"
  s.authors = ["Scott Francis", "Simon Eskildsen", "Dale Hamel"]
  s.email = "opensource@shopify.com"
  s.license = "MIT"

  s.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "bug_tracker_uri" => "https://github.com/Shopify/semian/issues",
    "changelog_uri" => "https://github.com/Shopify/semian/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://github.com/Shopify/semian",
    "homepage_uri" => "https://github.com/Shopify/semian",
    "source_code_uri" => "https://github.com/Shopify/semian",
  }

  s.add_runtime_dependency("concurrent-ruby")
  s.add_runtime_dependency("logger")

  s.required_ruby_version = ">= 3.2.0"

  s.files = Dir["{lib,ext}/**/**/*.{rb,h,c}"]
  s.files += ["LICENSE.md", "README.md"]
  s.extensions = ["ext/semian/extconf.rb"]
  s.require_paths = ["lib"]
end
