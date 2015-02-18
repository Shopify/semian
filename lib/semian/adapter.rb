module Semian
  module Adapter
    def semian_identifier
      raise NotImplementedError.new("Semian adapters must implement a `semian_identifier` method")
    end

    def semian_resource
      @semian_resource ||= ::Semian.retrieve_or_register(semian_identifier, **semian_options)
    end

    private

    def acquire_semian_resource(scope:, &block)
      return yield if resource_already_acquired?
      semian_resource.acquire(scope: scope) do
        mark_resource_as_acquired(&block)
      end
    rescue ::Semian::OpenCircuitError => error
      raise self.class::CircuitOpenError.new(semian_identifier, error)
    rescue ::Semian::BaseError => error
      raise self.class::ResourceOccupiedError.new(semian_identifier, error)
    end

    def semian_options
      raise NotImplementedError.new("Semian adapters must implement a `semian_options` method")
    end

    def resource_already_acquired?
      @resource_acquired
    end

    def mark_resource_as_acquired
      previous = @resource_acquired
      @resource_acquired = true
      yield
    ensure
      @resource_acquired = previous
    end
  end
end
