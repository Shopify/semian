# frozen_string_literal: true

module Semian
  class ConfigurationValidator
    class ValidationError < StandardError; end

    def validate!(configuration, adapter: nil)
      new(configuration, adapter: adapter).validate!
    end

    def initialize(configuration, adapter: nil)
      @configuration = configuration
      @adapter = adapter
    end

    def validate!
      validate_bulkhead_configuration!
      validate_circuit_breaker_configuration!
      validate_resource_name!
      validate_adapter_specific_configuration! if @adapter
      true
    end

    private

    def validate_bulkhead_configuration!
      tickets = @configuration[:tickets]
      quota = @configuration[:quota]

      if tickets.nil? && quota.nil?
        raise ValidationError, "Semian configuration requires either the :tickets or :quota parameter, you provided neither"
      end

      if tickets && quota
        raise ValidationError, "Semian configuration requires either the :tickets or :quota parameter, you provided both"
      end

      validate_quota!(quota) if quota
      validate_tickets!(tickets) if tickets
    end

    def validate_circuit_breaker_configuration!
      return unless @configuration[:circuit_breaker]

      validate_thresholds!
      validate_timeouts!
    end

    def validate_thresholds!
      success_threshold = @configuration[:success_threshold]
      error_threshold = @configuration[:error_threshold]

      if success_threshold && success_threshold <= 0
        raise ValidationError, "success_threshold must be positive"
      end

      if error_threshold && error_threshold <= 0
        raise ValidationError, "error_threshold must be positive"
      end
    end

    def validate_timeouts!
      error_timeout = @configuration[:error_timeout]
      error_threshold_timeout = @configuration[:error_threshold_timeout]
      lumping_interval = @configuration[:lumping_interval]

      if error_timeout && error_timeout < 0
        raise ValidationError, "error_timeout must be non-negative"
      end

      if error_threshold_timeout && error_threshold_timeout < 0
        raise ValidationError, "error_threshold_timeout must be non-negative"
      end

      if lumping_interval && error_threshold_timeout && lumping_interval > error_threshold_timeout
        raise ValidationError, "lumping_interval (#{lumping_interval}) must be less than error_threshold_timeout (#{error_threshold_timeout})"
      end
    end

    def validate_quota!(quota)
      unless quota.is_a?(Numeric) && quota > 0 && quota <= 1
        raise ValidationError, "quota must be a decimal between 0 and 1"
      end
    end

    def validate_tickets!(tickets)
      unless tickets.is_a?(Integer) && tickets >= 0 && tickets <= Semian::MAX_TICKETS
        raise ValidationError, "ticket count must be a non-negative integer and less than #{Semian::MAX_TICKETS}"
      end
    end

    def validate_resource_name!
      name = @configuration[:name]
      return unless name

      unless name.is_a?(String) || name.is_a?(Symbol)
        raise ValidationError, "name must be a symbol or string"
      end

      if Semian.resources[name.to_s]
        raise ValidationError, "Resource with name #{name} is already registered"
      end
    end

    def validate_adapter_specific_configuration!
      case @adapter
      when :net_http
        validate_net_http_configuration!
      when :grpc
        validate_grpc_configuration!
      end
    end

    def validate_net_http_configuration!
      if @configuration[:dynamic] && !@configuration[:name]
        raise ValidationError, "Dynamic configuration requires a name parameter"
      end
    end

    def validate_grpc_configuration!
      if @configuration[:dynamic] && !@configuration[:name]
        raise ValidationError, "Dynamic configuration requires a name parameter"
      end
    end
  end
end
