# frozen_string_literal: true

source "https://rubygems.org"

gem "rake"

group :test do
  gem "benchmark-memory"
  gem "memory_profiler"
  gem "minitest"
  gem "mocha"
  gem "pry-byebug", require: false
  gem "rake-compiler"
  gem "timecop"
  gem "toxiproxy"
  gem "webrick"

  gem "grpc", "1.46.3"
  gem "mysql2", "~> 0.5"
  gem "activerecord", ">= 7.0.3"
  gem "hiredis-client", github: "redis-rb/redis-client"
  gem "hiredis", "~> 0.6"
  gem "redis", github: "redis/redis-rb"
end

group :lint do
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
  gem "rubocop-shopify", require: false
  gem "rubocop", require: false
end

gemspec
