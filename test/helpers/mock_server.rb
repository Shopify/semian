# frozen_string_literal: true

require 'webrick'

module MockServer
  extend self

  def start(hostname:, port:)
    tid = Thread.new do
      new_server(hostname, port).start
    end
    poll_until_ready(hostname: hostname, port: port)
    puts "Created test server #{tid}, port: #{port}"
    tid
  end

  def cleanup(tid)
    Thread.kill(tid)
    puts "Killed test server #{tid}."
  end

  def new_server(hostname, port)
    server = TCPServer.new(hostname, port)
    while (sock = server.accept)
      begin
        config = WEBrick::Config::HTTP
        res = WEBrick::HTTPResponse.new(config)
        req = WEBrick::HTTPRequest.new(config)
        req.parse(sock)

        response_code = req.path_info.delete("/")
        response_code = 200 if response_code == ""

        res.status = response_code
        res.content_type = 'text/html'
      rescue WEBrick::HTTPStatus::EOFError, WEBrick::HTTPStatus::BadRequest
        res.status = 200
        res.content_type = 'text/html'
      ensure
        res.send_response(sock)
      end
    end
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
