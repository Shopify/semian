# frozen_string_literal: true

source "https://rubygems.org"

gem "rake"
gem "rake-compiler"

group :test do
  gem "benchmark-memory"
  gem "benchmark-ips"
  gem "memory_profiler"
  gem "minitest"
  gem "mocha"
  gem "pry-byebug", require: false
  gem "toxiproxy"
  gem "webrick"

  # The last stable version for MacOS ARM darwin
  gem "grpc", "1.65.2"
  gem "mysql2", "~> 0.5"
  gem "trilogy", "~> 2.8"
  gem "activerecord", github: "rails/rails", branch: "main"
  gem "hiredis", "~> 0.6"
  # NOTE: v0.12.0 required for ruby 3.2.0. https://github.com/redis-rb/redis-client/issues/58
  gem "hiredis-client", ">= 0.12.0"
  gem "redis"
end

group :lint do
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
  gem "rubocop-shopify", require: false
  gem "rubocop", require: false
end

gemspec
