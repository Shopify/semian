# frozen_string_literal: true

source "https://rubygems.org"

gem "rake"
gem "rake-compiler"

group :test do
  gem "benchmark-memory"
  gem "memory_profiler"
  gem "minitest"
  gem "mocha"
  gem "pry-byebug", require: false
  gem "toxiproxy"
  gem "webrick"

  # The last stable version for MacOS ARM darwin
  gem "grpc", "1.47.0"
  gem "mysql2", "~> 0.5"
  gem "activerecord", ">= 7.0.3"
  gem "hiredis", "~> 0.6"
  gem "hiredis-client"
  gem "redis"
end

group :lint do
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
  gem "rubocop-shopify", require: false
  gem "rubocop", require: false
end

gemspec
