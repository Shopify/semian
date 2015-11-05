module ClassTestHelper
  def retrieve_descendants(klass)
    ObjectSpace.each_object(klass.singleton_class).to_a
  end
end
