# frozen_string_literal: true

require "async/service/generic"
require "async/container/supervisor"
require_relative "state_service"
require_relative "controller"

module Semian
  module PodPID
    class Service < Async::Service::Generic
      def setup(container)
        super

        container.run(name: self.class.name, count: 1, restart: true) do |instance|
          Async do
            if @environment.implements?(Async::Container::Supervisor::Supervised)
              @evaluator.make_supervised_worker(instance).run
            end

            instance.ready!

            config = Semian::DEFAULT_PID_CONFIG.merge(
              wal_path: ENV.fetch("SEMIAN_PID_WAL_PATH", WAL::DEFAULT_PATH),
            )

            state_service = StateService.new(**config)
            Controller.start(state_service)
          end
        end
      end
    end
  end
end

