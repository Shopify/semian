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
end
