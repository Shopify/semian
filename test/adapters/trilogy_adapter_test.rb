# frozen_string_literal: true

require "test_helper"
require "semian/trilogy_adapter"

class TrilogyAdapterTest < Minitest::Test
  ERROR_TIMEOUT = 5
  ERROR_THRESHOLD = 1
  SEMIAN_OPTIONS = {
    name: "testing",
    tickets: 1,
    timeout: 0,
    error_threshold: ERROR_THRESHOLD,
    success_threshold: 2,
    error_timeout: ERROR_TIMEOUT,
  }

  def setup
    @proxy = Toxiproxy[:semian_test_mysql]
    Semian.destroy(:trilogy_adapter_testing)

    @configuration = {
      adapter: "trilogy",
      username: "root",
      host: SemianConfig["toxiproxy_upstream_host"],
      port: SemianConfig["mysql_toxiproxy_port"],
    }
    @adapter = trilogy_adapter
  end

  def test_semian_identifier
    assert_equal(:"trilogy_adapter_testing", @adapter.semian_identifier)

    adapter = trilogy_adapter(host: "127.0.0.1", semian: { name: nil })
    assert_equal(:"trilogy_adapter_127.0.0.1:13306", adapter.semian_identifier)

    adapter = trilogy_adapter(host: "example.com", port: 42, semian: { name: nil })
    assert_equal(:"trilogy_adapter_example.com:42", adapter.semian_identifier)
  end

  def test_semian_can_be_disabled
    resource = trilogy_adapter(
      host: SemianConfig["toxiproxy_upstream_host"],
      port: SemianConfig["mysql_toxiproxy_port"],
      semian: false,
    ).semian_resource

    assert_instance_of(Semian::UnprotectedResource, resource)
  end

  private

  def trilogy_adapter(**config_overrides)
    ActiveRecord::ConnectionAdapters::TrilogyAdapter
      .new(@configuration.merge(config_overrides))
  end
end
