# frozen_string_literal: true

require 'webrick'

module MockServer
  extend self

  def start(hostname:, port:)
    tid = Thread.new do
      TestServer.new(hostname: hostname, port: port).start
    end
    poll_until_ready(hostname: hostname, port: port)
    puts "Created test server #{tid}, port: #{port}"
    tid
  end

  def cleanup(tid)
    Thread.kill(tid)
    puts "Killed test server #{tid}."
  end

  def poll_until_ready(hostname:, port:, time_to_wait: 1)
    start_time = Time.now.to_i
    begin
      TCPSocket.new(hostname, port).close
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      if Time.now.to_i > start_time + time_to_wait
        raise "Couldn't reach the service on hostname #{hostname} port #{port} after #{time_to_wait}s"
      else
        retry
      end
    end
  end
end

class TestServer
  def initialize(hostname:, port:)
    @server = WEBrick::HTTPServer.new(
      Port:  port,
      BindAddress: hostname,
      Logger: WEBrick::Log.new("/dev/null"),
      AccessLog: [],
    )
    @server.mount '/', Handler
  end

  def start
    @server.start
  end
end

class Handler < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(request, response) # rubocop:disable all
    response_code = request.path.delete("/")
    response_code = '200' if response_code == ""
    response.status = response_code
    response['Content-Type'] = 'text/html'
  end
end
