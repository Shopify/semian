# frozen_string_literal: true

module Semian
  class ConfigurationValidator
    def initialize(name, configuration)
      @name = name
      @configuration = configuration
      @adapter = configuration[:adapter]
      @force_config_validation = force_config_validation?

      unless @force_config_validation
        Semian.logger.warn(
          "Semian is running in log-mode for configuration validation. This means that Semian will not raise an error if the configuration is invalid. This is not recommended for production environments.\n\n[IMPORTANT] IN FUTURE RELEASES, STRICT CONFIGURATION VALIDATION WILL BE THE DEFAULT BEHAVIOR. PLEASE UPDATE YOUR CONFIGURATION TO USE `force_config_validation: true` TO ENABLE STRICT CONFIGURATION VALIDATION. ALLOWING MISCONFIGURATIONS IN FUTURE RELEASES WILL BREAK YOUR SEMIAN.\n---\n",
        )
      end
    end

    def validate!
      validate_circuit_breaker_or_bulkhead!
      validate_bulkhead_configuration!
      validate_circuit_breaker_configuration!
      validate_resource_name!
      true
    end

    private

    def hint_format(message)
      "\n\nHINT: #{message}\n---"
    end

    def raise_or_log_validation_required!(message)
      if @force_config_validation
        raise ArgumentError, message
      else
        Semian.logger.warn(message)
      end
    end

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
        raise ArgumentError, "Bulkhead configuration require either the :tickets or :quota parameter, you provided neither"
      end

      if tickets && quota
        raise ArgumentError, "Bulkhead configuration require either the :tickets or :quota parameter, you provided both"
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
        err = "success_threshold must be positive, got #{success_threshold}"

        if success_threshold == 0
          err += hint_format("Are you sure that this is what you want? This will close the circuit breaker immediately after `error_timeout` seconds without checking the resource!")
        end

        raise_or_log_validation_required!(err)
      end

      if error_threshold && error_threshold <= 0
        err = "error_threshold must be positive, got #{error_threshold}"

        if error_threshold == 0
          err += hint_format("Are you sure that this is what you want? This will open the circuit breaker indefinitely!")
        end

        raise_or_log_validation_required!(err)
      end
    end

    def validate_timeouts!
      error_timeout = @configuration[:error_timeout]
      error_threshold_timeout = @configuration[:error_threshold_timeout]
      error_threshold = @configuration[:error_threshold]
      lumping_interval = @configuration[:lumping_interval]
      half_open_resource_timeout = @configuration[:half_open_resource_timeout]

      unless error_timeout && error_timeout > 0
        err = "error_timeout must be positive, got #{error_timeout}"

        if error_timeout == 0
          err += hint_format("Are you sure that this is what you want? This will close the circuit breaker immediately after opening it!")
        end

        raise_or_log_validation_required!(err)
      end

      unless error_threshold_timeout.nil? || error_threshold_timeout > 0
        err = "error_threshold_timeout must be positive, got #{error_threshold_timeout}"

        if error_threshold_timeout == 0
          err += hint_format("Are you sure that this is what you want? This will almost never open the circuit breaker since the time interval to catch errors is 0!")
        end

        raise_or_log_validation_required!(err)
      end

      unless half_open_resource_timeout.nil? || half_open_resource_timeout > 0
        err = "half_open_resource_timeout must be positive, got #{half_open_resource_timeout}"

        if half_open_resource_timeout == 0
          err += hint_format("Are you sure that this is what you want? This will never half-open the circuit breaker!")
        end

        raise_or_log_validation_required!(err)
      end

      unless lumping_interval.nil? || lumping_interval >= 0
        raise_or_log_validation_required!("lumping_interval must be non-negative, got #{lumping_interval}")
      end

      if lumping_interval && lumping_interval == 0
        Semian.logger.warn("lumping_interval is 0, this means lumping is disabled!")
      end

      # You might be wondering why not check just check lumping_interval * error_threshold <= error_threshold_timeout
      # The reason being is that since the lumping_interval starts at the first error, we count the first error
      # at second 0. So we need to subtract 1 from the error_threshold to get the correct minimum time to reach the
      # error threshold. error_threshold_timeout cannot be less than this minimum time.
      #
      # For example,
      #
      # error_threshold = 3
      # error_threshold_timeout = 10
      # lumping_interval = 4
      #
      # The first error could be counted at second 0, the second error could be counted at second 4, and the third
      # error could be counted at second 8. So this is a valid configuration.

      unless lumping_interval.nil? || error_threshold_timeout.nil? || lumping_interval * (error_threshold - 1) <= error_threshold_timeout
        err = "constraint violated: lumping_interval * (error_threshold - 1) <= error_threshold_timeout, got lumping_interval: #{lumping_interval}, error_threshold: #{error_threshold}, error_threshold_timeout: #{error_threshold_timeout}"
        err += hint_format("lumping_interval starts from the first error and not in a fixed window. So you can fit n errors in n-1 seconds, since error 0 starts at 0 seconds. Ensure that you can fit `error_threshold` errors lumped in `lumping_interval` seconds within `error_threshold_timeout` seconds.")

        raise_or_log_validation_required!(err)
      end
    end

    def validate_quota!(quota)
      unless quota.is_a?(Numeric) && quota > 0 && quota < 1
        err = "quota must be a decimal between 0 and 1, got #{quota}"

        if quota == 0
          err += hint_format("Are you sure that this is what you want? This is the same as assigning no workers to the resource, disabling the resource!")
        elsif quota == 1
          err += hint_format("Are you sure that this is what you want? This is the same as assigning all workers to the resource, disabling the bulkhead!")
          raise_or_log_validation_required!(err)
          return
        end

        raise ArgumentError, err
      end
    end

    def validate_tickets!(tickets)
      unless tickets.is_a?(Integer) && tickets > 0 && tickets < Semian::MAX_TICKETS
        err = "ticket count must be a positive integer and less than #{Semian::MAX_TICKETS}, got #{tickets}"

        if tickets == 0
          err += hint_format("Are you sure that this is what you want? This is the same as assigning no workers to the resource, disabling the resource!")
        elsif tickets == Semian::MAX_TICKETS
          err += hint_format("Are you sure that this is what you want? This is the same as assigning all workers to the resource, disabling the bulkhead!")
          raise_or_log_validation_required!(err)
          return
        end

        raise ArgumentError, err
      end
    end

    def validate_resource_name!
      unless @name.is_a?(String) || @name.is_a?(Symbol)
        raise_or_log_validation_required!("name must be a symbol or string, got #{@name}")
      end

      if Semian.resources[@name]
        err = "Resource with name #{@name} is already registered"
        err += hint_format("Are you sure that this is what you want? This will override an existing resource with the same name!")

        raise_or_log_validation_required!(err)
      end
    end

    def force_config_validation?
      if @configuration[:force_config_validation].nil?
        Semian.default_force_config_validation
      else
        @configuration[:force_config_validation]
      end
    end
  end
end
