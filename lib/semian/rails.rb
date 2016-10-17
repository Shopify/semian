require 'active_record/connection_adapters/abstract_adapter'

class ActiveRecord::ConnectionAdapters::AbstractAdapter
  def semian_resource
    @connection.semian_resource
  end
end
