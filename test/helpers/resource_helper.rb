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
      begin
        resource.destroy
      rescue
        nil
      end
    end
    @resources = []
  end
end
