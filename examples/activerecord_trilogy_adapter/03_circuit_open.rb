# frozen_string_literal: true

require "semian"
require "semian/activerecord_trilogy_adapter"
require_relative "../colors"

puts "> Starting example #{__FILE__}".blue.bold
puts
puts "> Initialize print Semian state changes".blue.bold
Semian.subscribe do |event, resource, scope, adapter|
  puts "[semian] adapter=#{adapter} scope=#{scope} event=#{event} " \
    "resource_name=#{resource.name} resource=#{resource}".gray
end

SEMIAN_PARAMETERS = {
  circuit_breaker: true,
  success_threshold: 3,
  error_threshold: 2,
  error_timeout: 3,
  bulkhead: false,
}

host = ENV.fetch("MYSQL_HOST", "localhost")
healthy_port = Integer(ENV.fetch("MYSQL_PORT", 3306))
unhealthy_port = healthy_port + 1

puts "> Configure Circuit breaker for TrilogyAdapter".blue.bold
puts "  Setup circuit breaker for all connections".blue
puts "  " + "Bulkhead is DISABLED.".blue.underline
configuration = {
  adapter: "trilogy",
  username: "root",
  host: host,
  port: unhealthy_port,
  database: "mysql",
  semian: SEMIAN_PARAMETERS,
}

adapter = ActiveRecord::ConnectionAdapters::TrilogyAdapter.new(configuration)

puts "> Test requests".blue.bold

puts " >> 1. Access to unavailable MySQL on port #{unhealthy_port} - fail".magenta
begin
  adapter.execute("SELECT 1;")
rescue ActiveRecord::ConnectionNotEstablished => e
  puts "   >> Could not connect: #{e.message}".brown
end

puts
puts " >> 2. Access to unavailable MySQL on port #{unhealthy_port} - fail".magenta
begin
  adapter.execute("SELECT 1;")
rescue ActiveRecord::ConnectionNotEstablished => e
  puts "   >> Could not connect: #{e.message}".brown
end

resource = Semian[:"mysql_#{host}:3307"]
raise "Semian should no be closed" if resource.closed?

puts "   !!! Semian changed state from `closed` to `open` and record last error exception !!!".red.bold
puts

puts " >> 3. Access to unavailable MySQL on port #{unhealthy_port} - fail".magenta
begin
  adapter.execute("SELECT 1;")
rescue ActiveRecord::ConnectionAdapters::TrilogyAdapter::CircuitOpenError => e
  puts "   >> Semian is open: #{e.message}".brown
  puts "   !!! Semian open and no request made to mysql !!!".red.bold
end

adapter = ActiveRecord::ConnectionAdapters::TrilogyAdapter.new(configuration.merge(port: healthy_port))
puts " >> 4. Access to healthy MySQL still works #{healthy_port}".cyan
adapter.execute("SELECT 1;")
puts
puts " >> Review semian state:".blue
resource = Semian[:"mysql_#{host}:3306"]
puts "resource_name=#{resource.name} resource=#{resource} " \
  "closed=#{resource.closed?} open=#{resource.open?} " \
  "half_open=#{resource.half_open?}".gray
puts

puts " >> 5. Waiting for error_timeout (#{SEMIAN_PARAMETERS[:error_timeout]} sec)".blue
sleep(SEMIAN_PARAMETERS[:error_timeout])
puts

adapter = ActiveRecord::ConnectionAdapters::TrilogyAdapter.new(configuration.merge(port: unhealthy_port))
puts " >> 6. Try to connect to unhelathy DB on #{unhealthy_port} and switch back to open circuit".magenta
begin
  adapter.execute("SELECT 1;")
rescue ActiveRecord::ConnectionNotEstablished => e
  puts "   >> Could not connect: #{e.message}".brown
end
puts "   !!! Semian changed state from `half_open` to `open` again !!!".red.bold
puts

puts "> That's all Folks!".green
