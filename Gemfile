# frozen_string_literal: true

source "https://rubygems.org"

group :test do
  gem "benchmark-memory"
  gem "grpc"
  gem "hiredis", "~> 0.6"
  gem "memory_profiler"
  gem "minitest"
  gem "mocha"
  gem "mysql2", "~> 0.5", github: "brianmario/mysql2"
  gem "pry-byebug", require: false
  gem "rake-compiler"
  gem "rake"
  gem "redis-client", "0.4.0"
  gem "redis"
  gem "timecop"
  gem "toxiproxy"
  gem "webrick"
end

group :lint do
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
  gem "rubocop-shopify", require: false
  gem "rubocop", require: false
end

gemspec
