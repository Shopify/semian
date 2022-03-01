require 'active_record/connection_adapters/abstract_adapter'

class ActiveRecord::ConnectionAdapters::AbstractAdapter
  def semian_resource
    # support for https://github.com/rails/rails/commit/d86fd6415c0dfce6fadb77e74696cf728e5eb76b
    connection = instance_variable_defined?(:@raw_connection) ? @raw_connection : @connection
    connection.semian_resource
  end
end
