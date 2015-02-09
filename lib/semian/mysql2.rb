require 'semian'
require 'mysql2'

class Mysql2::SemianError < Mysql2::Error
  def initialize(semian_identifier, *args)
    super(*args)
    @semian_identifier = semian_identifier
  end

  def to_s
    "[#{@semian_identifier}] #{super}"
  end
end

module Semian
  module Mysql2
    def semian_identifier
      @semian_identifier ||= begin
        name = query_options[:semian] && query_options[:semian][:name]
        name ||= [query_options[:host] || 'localhost', query_options[:port] || 3306].join(':')
        :"mysql_#{name}"
      end
    end

    def query(*)
      semian_resource.acquire { super }
    rescue ::Semian::BaseError => error
      raise ::Mysql2::SemianError.new(semian_identifier, error)
    end

    private

    def connect(*)
      semian_resource.acquire { super }
    rescue Semian::BaseError => error
      raise ::Mysql2::SemianError.new(semian_identifier, error)
    end

    def semian_resource
      @semian_resource ||= ::Semian.register(semian_identifier, **semian_options)
    end

    def semian_options
      options = query_options[:semian] || {}
      options = options.map { |k, v| [k.to_sym, v] }.to_h
      options.delete(:name)
      options
    end
  end
end

::Mysql2::Client.prepend(Semian::Mysql2)
