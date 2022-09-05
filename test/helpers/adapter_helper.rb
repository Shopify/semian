# frozen_string_literal: true

require "semian/adapter"

module Semian
  module AdapterTest
    include Semian::Adapter

    def semian_identifier
      :semian_adapter_test
    end

    def raw_semian_options
      @client_options
    end

    def resource_exceptions
      []
    end
  end

  class AdapterTestClient
    include AdapterTest

    def initialize(**args)
      @client_options = args.merge(success_threshold: 1,
        error_threshold: 1,
        error_timeout: 1)
    end

    def ==(other)
      inspect == other.inspect
    end
  end
end
