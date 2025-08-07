# frozen_string_literal: true

require "semian"
require "semian/net_http"
require_relative "../colors"

puts "> Starting example #{__FILE__}".blue.bold
puts "  Example shows that Circuit breaker share the state between Threads.".gray
puts
puts "> Initialize print Semian state changes".blue.bold
Semian.subscribe do |event, resource, scope, adapter, payload|
  thread_id = Thread.current.object_id
  puts "[thread=#{thread_id}]   [semian] adapter=#{adapter} " \
    "scope=#{scope} event=#{event} " \
    "resource_name=#{resource.name} resource=#{resource} " \
    "payload=#{payload}".gray
end

SEMIAN_PARAMETERS = {
  circuit_breaker: true,
  success_threshold: 3,
  error_threshold: 2,
  error_timeout: 5,
  bulkhead: false,
}.freeze

puts "> Configure Circuit breaker for Net::HTTP".blue.bold
puts "  Setup single circuit breaker for all shopify.com requests".blue
puts "  without limitation per port.".blue
puts "  " + "Bulkhead is DISABLED.".blue.underline
Semian::NetHTTP.semian_configuration = proc do |host, port|
  thread_id = Thread.current.object_id
  puts "[thread=#{thread_id}]   [semian/http] invoked config in for " \
    "host=#{host}(#{host.class}) port=#{port}(#{port.class})".gray

  if host == "shopify.com"
    puts "[thread=#{thread_id}]   [semian/http] set resource name shopify_com with any port".gray
    SEMIAN_PARAMETERS.merge(name: "shopify_com")
  else
    puts "[thread=#{thread_id}]   [semian/http] skip semian initialization".gray
    nil
  end
end

puts "> Test requests in threads".blue.bold

success_host = URI("http://shopify.com/index.html")
bad_host = URI("http://shopify.com:81/index.html")

Thread.abort_on_exception = true

worker_foo = Thread.new do
  thread_id = Thread.current.object_id
  puts "[thread=#{thread_id}] >> 1. Request to http://shopify.com/index.html - success".cyan
  response = Net::HTTP.get_response(success_host)
  puts "[thread=#{thread_id}]   > Response status: #{response.code}"
  puts
  sleep(4)
  puts "[thread=#{thread_id}] >> 3. Request to http://shopify.com/index.html - success".cyan
  response = Net::HTTP.get_response(success_host)
  puts "[thread=#{thread_id}]   > Response status: #{response.code}"
  puts
  sleep(5)
  puts "[thread=#{thread_id}] >> 6. Request to HEALTHY http://shopify.com/index.html in separate THREAD - fail".magenta.bold
  begin
    Net::HTTP.get_response(success_host)
  rescue Net::CircuitOpenError => e
    puts "[thread=#{thread_id}]   >> Semian is open: #{e.message}".brown
    puts "[thread=#{thread_id}]   !!! Semian open and no request made to shopify.com:80, even it is HEALTHY !!!".red.bold
  end
  puts

  puts "[thread=#{thread_id}] >> Review semian state:".blue
  resource = Semian["nethttp_shopify_com"]
  puts "[thread=#{thread_id}]  resource_name=#{resource.name} resource=#{resource} " \
    "closed=#{resource.closed?} open=#{resource.open?} " \
    "half_open=#{resource.half_open?}".gray
  puts
end

worker_bar = Thread.new do
  thread_id = Thread.current.object_id
  sleep(1)
  puts "[thread=#{thread_id}] >> 2. Request to http://shopify.com:81/index.html - fail".magenta
  begin
    Net::HTTP.start("shopify.com", 81, open_timeout: 3) do |http|
      http.request_get(bad_host)
    end
  rescue Net::OpenTimeout => e
    puts "[thread=#{thread_id}]   >> Could not connect: #{e.message}".brown
  end
  puts

  sleep(1.5)

  puts "[thread=#{thread_id}] >> 4. Request to http://shopify.com:81/index.html - fail".magenta
  begin
    Net::HTTP.start("shopify.com", 81, open_timeout: 3) do |http|
      http.request_get(bad_host)
    end
  rescue Net::OpenTimeout => e
    puts "[thread=#{thread_id}]   >> Could not connect: #{e.message}".brown
  end

  resource = Semian["nethttp_shopify_com"]
  raise "The state should be open - because expected 2 failed requests in last 5 seconds." unless resource.open?

  puts "[thread=#{thread_id}]   !!! Semian changed state from `closed` to `open` and record last error exception !!!".red.bold
  puts

  puts "[thread=#{thread_id}] >> 5. Request to http://shopify.com:81/index.html - fail".magenta
  begin
    Net::HTTP.start("shopify.com", 81, open_timeout: 3) do |http|
      http.request_get(bad_host)
    end
  rescue Net::CircuitOpenError => e
    puts "[thread=#{thread_id}]  >> Semian is open: #{e.message}".brown
  rescue => e
    raise "Unexpected exception: #{e.messge} (#{e.class}). Check if Semian resource error_threshold_reached?"
  end
  puts

  puts "[thread=#{thread_id}] >> Review semian state:".blue
  resource = Semian["nethttp_shopify_com"]
  puts "[thread=#{thread_id}]  resource_name=#{resource.name} resource=#{resource} " \
    "closed=#{resource.closed?} open=#{resource.open?} " \
    "half_open=#{resource.half_open?}".gray
  puts
end

worker_foo.join
worker_bar.join

puts "> That's all Folks!".green
