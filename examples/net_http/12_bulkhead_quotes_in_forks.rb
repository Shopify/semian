# frozen_string_literal: true

require "semian"
require "semian/net_http"
require_relative "../colors"

puts "> Starting example #{__FILE__}".blue.bold
puts "  Example shows that Bulkhead blocks concurent requests, while there is no free tickets available.".gray
puts
puts "> Initialize print Semian state changes".blue.bold
Semian.subscribe do |event, resource, scope, adapter|
  pid = Process.pid
  puts "[pid=#{pid}][semian] adapter=#{adapter} scope=#{scope} event=#{event} " \
    "resource_name=#{resource.name} resource=#{resource}".gray
end

SEMIAN_PARAMETERS = {
  bulkhead: true,
  quota: 1, # Tickets calculated base on number of workers
  timeout: 1, # Timeout in seconds (1 sec) to wait to get a free ticket.
  circuit_breaker: false,
}.freeze

Semian::NetHTTP.semian_configuration = proc do |host, port|
  pid = Process.pid
  puts "[pid=#{pid}][semian/http] invoked config for host=#{host}(#{host.class}) port=#{port}(#{port.class})".gray

  if host == "shopify.com"
    SEMIAN_PARAMETERS.merge(name: "shopify_com")
  end
end

def print_semaphore_information(resource = nil)
  resource ||= Semian["nethttp_shopify_com"]
  return if resource.nil?

  sem_key = resource.bulkhead.key
  system("ipcs -si $(ipcs -s | grep #{sem_key} | awk '{print $2}')")
end

pid = Process.pid
puts "[pid=#{pid}] >> Request to http://shopify.com:80/index.html - success".cyan.bold
uri = URI("http://shopify.com:80/index.html")
Net::HTTP.get_response(uri)

puts "> Bulkhead's semaphore information:".blue.bold
puts "  Read more in README.md > Bulkhead debugging on linux".gray
puts "  a. System semaphore limits:"
system "cat /proc/sys/kernel/sem"
puts

puts "  b. Semaphore values for resource:"
print_semaphore_information
puts "  Important lines with id 1 (current tickets) and 2 (max tickets).".italic.gray
puts "  It is calculated base on line with id 3 (workers number) and quota #{SEMIAN_PARAMETERS[:quota]}.".italic.gray
puts

puts "> Test requests in forks".blue.bold

pid = Process.pid
puts "[pid=#{pid}] >> Request to http://shopify.com:80/index.html - success".cyan.bold
uri = URI("http://shopify.com:80/index.html")
Net::HTTP.get_response(uri)

workers = []

workers << fork do
  pid = Process.pid
  puts "[pid=#{pid}] >> Request to http://shopify.com:81/index.html to use all Tickets - fail".magenta.bold
  Net::HTTP.start("shopify.com", 81, open_timeout: 5) do |http|
    http.request_get(bad_host)
  end
  raise "Should not get to this line."
rescue Errno::EADDRNOTAVAIL, Net::OpenTimeout => e
  puts "[pid=#{pid}] EXPECTED networking problem that blocked the last ticket: #{e.class}: #{e.message}".blue
end

5.times do |_i|
  workers << fork do
    pid = Process.pid
    puts "[pid=#{pid}] > Unregister resources to make sure other workers know about new worker appeared.".blue.bold
    Semian.unregister_all_resources
    puts "[pid=#{pid}] >> Request to http://shopify.com/index.html to use all Tickets - success".cyan
    Net::HTTP.get_response(uri)
  end
end

workers.each do |w|
  Process.waitpid(w)
end

puts "[pid=#{pid}] > Unregister resources to make sure other workers know about new worker appeared.".blue.bold
Semian.unregister_all_resources
print_semaphore_information

puts "> That's all Folks!".green
