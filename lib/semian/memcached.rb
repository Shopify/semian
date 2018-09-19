require 'semian/adapter'
require 'memcached'

module Semian
  module Memcached
    include Semian::Adapter

    class SemianError < ::Memcached::Error
      def initialize(semian_identifier, *args)
        super(*args)
        @semian_identifier = semian_identifier
      end
    end

    ResourceBusyError = Class.new(SemianError)

    def semian_identifier
      @semian_identifier ||= begin
        name = semian_options && semian_options[:name]
        ["memcached", name].compact.join("_").to_sym
      end
    end

    def raw_semian_options
      @options[:semian].merge(circuit_breaker: false)
    end

    %i(
      set
      add
      increment
      decrement
      replace
      append
      prepend
      delete
      exist
    ).each do |meth|
      raise "Memcached##{meth} is not defined." unless ::Memcached.method_defined?(meth)

      define_method(meth) do |*args|
        acquire_semian_resource(adapter: :memcached, scope: :query) do
          super(*args)
        end
      end
    end

    private

    %i(
      single_get
      single_cas
      multi_get
      multi_cas
    ).each do |meth|
      raise "Memcached##{meth} is not defined." unless ::Memcached.private_method_defined?(meth)

      define_method(meth) do |*args|
        acquire_semian_resource(adapter: :memcached, scope: :query) do
          super(*args)
        end
      end
    end
  end
end

if Memcached::VERSION == "1.8.0"
  # Hack to go around the DEFAULTS arguments check
  Memcached::DEFAULTS.merge!(semian: nil)

  Memcached.prepend(Semian::Memcached)
end
