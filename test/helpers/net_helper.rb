module NetHelper
  def with_server(ports: [SemianConfig['http_port']], reset_semian_state: true)
    ports.each do |port|
      hostname = '0.0.0.0'
      begin
        server = nil
        server_threw_error = false
        server_thread = Thread.new do
          Thin::Logging.silent = true
          server = Thin::Server.new(hostname, port, RackServer)
          begin
            server.start
          rescue StandardError
            server_threw_error = true
            raise
          end
        end

        begin
          poll_until_ready(hostname: hostname, port: port)
        rescue RuntimeError
          server_thread.kill
          server_thread.join if server_threw_error
          raise
        end

        reset_semian_resource(hostname: SemianConfig['toxiproxy_upstream_host'], port: port) if reset_semian_state
        @proxy = Toxiproxy[:semian_test_net_http]
        yield(hostname, port.to_i)
      ensure
        server&.stop
        server_thread.kill
        poll_until_gone(hostname: hostname, port: port)
      end
    end
  end

  def with_toxic(hostname: SemianConfig['http_host'], upstream_port: SemianConfig['http_port'], toxic_port: upstream_port + 1)
    old_proxy = @proxy
    name = "semian_test_net_http_#{hostname}_#{upstream_port}<-#{toxic_port}"
    Toxiproxy.populate([
      {
        name: name,
        upstream: "#{hostname}:#{upstream_port}",
        listen: "#{SemianConfig['toxiproxy_upstream_host']}:#{toxic_port}",
      },
    ])
    @proxy = Toxiproxy[name]
    yield(name)
  rescue StandardError
  ensure
    @proxy = old_proxy
    begin
      Toxiproxy[name].destroy
    rescue StandardError
    end
  end

  def poll_until_ready(hostname: SemianConfig['http_host'], port: SemianConfig['http_port'], time_to_wait: 1)
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

  def poll_until_gone(hostname: SemianConfig['http_host'], port: SemianConfig['http_port'], time_to_wait: 1)
    start_time = Time.now.to_i
    loop do
      if Time.now.to_i > start_time + time_to_wait
        raise "Could still reach the service on hostname #{hostname} port #{port} after #{time_to_wait}s"
      end
      begin
        TCPSocket.new(hostname, port).close
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        return true
      end
    end
  end
end
