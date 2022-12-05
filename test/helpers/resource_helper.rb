# frozen_string_literal: true

module ResourceHelper
  private

  def create_resource(*args)
    @resources ||= []
    resource = Semian::Resource.new(*args)
    @resources << resource
    resource
  end

  def destroy_resources
    return unless @resources

    @resources.each do |resource|
      resource.destroy
    rescue
      nil
    end
    @resources = []
  end

  def destroy_all_semian_resources
    Semian.resources.values.each do |resource|
      resource.bulkhead&.unregister_worker
    rescue ::Semian::SyscallError
    end
    Semian.destroy_all_resources
    destroy_resources
    Semian.reset!
  end
end
