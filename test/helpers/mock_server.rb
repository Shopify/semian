# frozen_string_literal: true

require "webrick"

class MockServer
  class << self
    def start(hostname:, port:)
      new(hostname: hostname, port: port).tap do |server|
        server.start
        server.poll_until_ready
      end
    end
  end

  def initialize(hostname:, port:)
    @hostname = hostname
    @port = port
    @tid = nil
  end

  def start
    @tid = Thread.new do
      start_server
    end
  end

  def stop
    Thread.kill(@tid)
  end

  def start_server
    server = TCPServer.new(@hostname, @port)
    while (sock = server.accept)
      begin
        config = WEBrick::Config::HTTP
        res = WEBrick::HTTPResponse.new(config)
        req = WEBrick::HTTPRequest.new(config)
        req.parse(sock)

        response_code = req.path_info.delete("/")
        response_code = 200 if response_code == ""

        res.status = response_code
        res.content_type = "text/html"
      rescue WEBrick::HTTPStatus::EOFError, WEBrick::HTTPStatus::BadRequest
        res.status = 400
        res.content_type = "text/html"
      ensure
        res.send_response(sock)
      end
    end
  end

  def poll_until_ready(time_to_wait: 1)
    timer_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    TCPSocket.new(@hostname, @port).close
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - timer_start
    if elapsed > time_to_wait
      raise "Couldn't reach the service on hostname #{@hostname} port #{@port} after #{time_to_wait}s"
    end

    retry
  end
end
