# frozen_string_literal: true

require "semian"
require "semian/activerecord_trilogy_adapter"
require_relative "../colors"

puts "> Starting example #{__FILE__}".blue.bold

SEMIAN_PARAMETERS = {
  circuit_breaker: true,
  success_threshold: 1,
  error_threshold: 3,
  error_timeout: 3,
  bulkhead: false,
}

configuration = {
  adapter: "trilogy",
  username: "root",
  host: ENV.fetch("MYSQL_HOST", "localhost"),
  port: Integer(ENV.fetch("MYSQL_PORT", 3306)),
  database: "mysql",
  semian: SEMIAN_PARAMETERS,
}

adapter = ActiveRecord::ConnectionAdapters::TrilogyAdapter.new(configuration)
adapter.execute("SELECT 1;")

puts "> That's all Folks!".green
