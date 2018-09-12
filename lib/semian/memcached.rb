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
      name = semian_options && semian_options[:name]
      ["memcached", name].compact.join("_").to_sym
    end

    def raw_semian_options
      # disable semian when host ejection is enabled.
      return false if !!@options[:auto_eject_hosts]
      @options[:semian].merge(circuit_breaker: false)
    end

    # patch all the methods that actually interacts with memcached, not their higher level abstractions such
    # as #get or #cas.
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
      single_get
      single_cas
      multi_get
      multi_cas
    ).each do |meth|
      define_method(meth) do |*args|
        acquire_semian_resource(adapter: :memcached, scope: :query) do
          super(*args)
        end
      end
    end

    # Preserve single_get and single_cas private visibility
    private(
      :single_get,
      :single_cas,
      :multi_get,
      :multi_cas,
    )
  end
end

if Memcached::VERSION == "1.8.0"
  # Hack to go around the DEFAULTS arguments check
  Memcached::DEFAULTS.merge!(semian: nil)

  Memcached.prepend(Semian::Memcached)
end
