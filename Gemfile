# frozen_string_literal: true

source "https://rubygems.org"

gem "rake"
gem "rake-compiler"
gem "concurrent-ruby"

group :test do
  gem "benchmark-memory"
  gem "benchmark-ips"
  gem "memory_profiler"
  gem "minitest"
  gem "mocha"
  gem "pry-byebug", require: false
  gem "toxiproxy"
  gem "webrick"
  gem "rubystats"

  gem "bigdecimal"
  gem "mutex_m"
  gem "grpc", "1.76.0"
  gem "mysql2", "~> 0.5"
  gem "trilogy", "~> 2.9"
  gem "activerecord", github: "rails/rails", branch: "main"
  gem "hiredis", "~> 0.6"
  # NOTE: v0.12.0 required for ruby 3.2.0. https://github.com/redis-rb/redis-client/issues/58
  gem "hiredis-client", ">= 0.12.0"
  gem "redis"
  gem "debug"
end

group :lint do
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
  gem "rubocop", "~> 1.81", require: false
  gem "rubocop-shopify", "~> 2", require: false
  gem "rubocop-thread_safety", require: false
end

gemspec
