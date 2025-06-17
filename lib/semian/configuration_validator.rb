# frozen_string_literal: true

module Semian
  class ConfigurationValidator
    def initialize(name, configuration)
      @name = name
      @configuration = configuration
      @adapter = configuration[:adapter]
    end

    def validate!
      validate_circuit_breaker_or_bulkhead!
      validate_bulkhead_configuration!
      validate_circuit_breaker_configuration!
      validate_resource_name!
      true
    end

    private

    def require_keys!(required, options)
      diff = required - options.keys
      unless diff.empty?
        raise ArgumentError, "Missing required arguments for Semian: #{diff}"
      end
    end

    def validate_circuit_breaker_or_bulkhead!
      if (@configuration[:circuit_breaker] == false || ENV.key?("SEMIAN_CIRCUIT_BREAKER_DISABLED")) && (@configuration[:bulkhead] == false || ENV.key?("SEMIAN_BULKHEAD_DISABLED"))
        raise ArgumentError, "Both bulkhead and circuitbreaker cannot be disabled."
      end
    end

    def validate_bulkhead_configuration!
      return if ENV.key?("SEMIAN_BULKHEAD_DISABLED")
      return unless @configuration.fetch(:bulkhead, true)

      tickets = @configuration[:tickets]
      quota = @configuration[:quota]

      if tickets.nil? && quota.nil?
        raise ArgumentError, "Semian configuration require either the :tickets or :quota parameter, you provided neither"
      end

      if tickets && quota
        raise ArgumentError, "Semian configuration require either the :tickets or :quota parameter, you provided both"
      end

      validate_quota!(quota) if quota
      validate_tickets!(tickets) if tickets
    end

    def validate_circuit_breaker_configuration!
      return if ENV.key?("SEMIAN_CIRCUIT_BREAKER_DISABLED")
      return unless @configuration.fetch(:circuit_breaker, true)

      require_keys!([:success_threshold, :error_threshold, :error_timeout], @configuration)
      validate_thresholds!
      validate_timeouts!
    end

    def validate_thresholds!
      success_threshold = @configuration[:success_threshold]
      error_threshold = @configuration[:error_threshold]

      if success_threshold && success_threshold <= 0
        raise ArgumentError, "success_threshold must be positive"
      end

      if error_threshold && error_threshold <= 0
        raise ArgumentError, "error_threshold must be positive"
      end
    end

    def validate_timeouts!
      error_timeout = @configuration[:error_timeout]
      error_threshold_timeout = @configuration[:error_threshold_timeout]
      error_threshold = @configuration[:error_threshold]
      lumping_interval = @configuration[:lumping_interval]
      half_open_resource_timeout = @configuration[:half_open_resource_timeout]

      unless error_timeout && error_timeout >= 0
        raise ArgumentError, "error_timeout must be non-negative"
      end

      unless error_threshold_timeout.nil? || error_threshold_timeout >= 0
        raise ArgumentError, "error_threshold_timeout must be non-negative"
      end

      unless half_open_resource_timeout.nil? || half_open_resource_timeout >= 0
        raise ArgumentError, "half_open_resource_timeout must be non-negative"
      end

      unless lumping_interval.nil? || lumping_interval >= 0
        raise ArgumentError, "lumping_interval must be non-negative"
      end

      unless lumping_interval.nil? || error_threshold_timeout.nil? || lumping_interval * (error_threshold - 1) <= error_threshold_timeout
        raise ArgumentError, "constraint violated: lumping_interval * (error_threshold - 1) <= error_threshold_timeout, got lumping_interval: #{lumping_interval}, error_threshold: #{error_threshold}, error_threshold_timeout: #{error_threshold_timeout}"
      end

      unless half_open_resource_timeout.nil? || half_open_resource_timeout <= error_timeout
        raise ArgumentError, "constraint violated: half_open_resource_timeout <= error_timeout, got half_open_resource_timeout: #{half_open_resource_timeout}, error_timeout: #{error_timeout}"
      end

      unless half_open_resource_timeout.nil? || error_threshold_timeout.nil? || half_open_resource_timeout <= error_threshold_timeout
        raise ArgumentError, "constraint violated: half_open_resource_timeout <= error_threshold_timeout, got half_open_resource_timeout: #{half_open_resource_timeout}, error_threshold_timeout: #{error_threshold_timeout}"
      end
    end

    def validate_quota!(quota)
      unless quota.is_a?(Numeric) && quota > 0 && quota <= 1
        raise ArgumentError, "quota must be a decimal between 0 and 1"
      end
    end

    def validate_tickets!(tickets)
      unless tickets.is_a?(Integer) && tickets >= 0 && tickets <= Semian::MAX_TICKETS
        raise ArgumentError, "ticket count must be a non-negative integer and less than #{Semian::MAX_TICKETS}"
      end
    end

    def validate_resource_name!
      unless @name.is_a?(String) || @name.is_a?(Symbol)
        raise ArgumentError, "name must be a symbol or string"
      end

      if Semian.resources[@name]
        raise ArgumentError, "Resource with name #{@name} is already registered"
      end
    end
  end
end
