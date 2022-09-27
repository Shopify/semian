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
  gem "timecop"
  gem "toxiproxy"
  gem "webrick"

  gem "grpc", "1.46.3"
  gem "mysql2", "~> 0.5"
  gem "trilogy"
  gem "activerecord", github: "rails/rails", branch: "main"
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
