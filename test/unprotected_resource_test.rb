require 'test_helper'

class UnprotectedResourceTest < MiniTest::Unit::TestCase
  def setup
    @resource = Semian::UnprotectedResource.new(:foo)
  end

  def test_interface_is_the_same
    diff = Semian::ProtectedResource.public_instance_methods - Semian::UnprotectedResource.public_instance_methods
    assert_equal [], diff
  end

  def test_resource_name
    assert_equal :foo, @resource.name
  end

  def test_resource_tickets
    assert_equal(-1, @resource.tickets)
  end

  def test_resource_count
    assert_equal 0, @resource.count
  end

  def test_resource_semid
    assert_equal 0, @resource.semid
  end

  def test_resource_reset
    @resource.reset
  end

  def test_resource_destroy
    @resource.destroy
  end

  def test_resource_acquire
    acquired = false
    @resource.acquire do
      acquired = true
    end
    assert acquired
  end

  def test_resource_acquire_with_timeout
    acquired = false
    @resource.acquire(timeout: 2) do
      acquired = true
    end
    assert acquired
  end

  def test_request_is_allowed
    assert @resource.request_allowed?
  end

  def test_mark_failed
    @resource.mark_failed(:error)
  end
end
