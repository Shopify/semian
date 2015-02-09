require 'test/unit'
require 'semian/mysql2'

class TestMysql2 < Test::Unit::TestCase
  def test_semian_identifier
    assert_equal :mysql_foo, FakeMysql.new(semian: {name: 'foo'}).semian_identifier
    assert_equal :'mysql_localhost:3306', FakeMysql.new.semian_identifier
    assert_equal :'mysql_127.0.0.1:3306', FakeMysql.new(host: '127.0.0.1').semian_identifier
    assert_equal :'mysql_example.com:42', FakeMysql.new(host: 'example.com', port: 42).semian_identifier
  end

  def test_resource_acquisition_for_query
    client = Mysql2::Client.new(semian: {name: :testing, tickets: 1, timeout: 0})

    Semian[:mysql_testing].acquire do
      assert_raises Mysql2::SemianError do
        client.query('SELECT 1 + 1;')
      end
    end
  end

  def test_resource_acquisition_for_query
    client = Mysql2::Client.new(semian: {name: :testing, tickets: 1, timeout: 0})

    Semian[:mysql_testing].acquire do
      assert_raises Mysql2::SemianError do
        Mysql2::Client.new(semian: {name: :testing, tickets: 1, timeout: 0})
      end
    end
  end

  private

  class FakeMysql < Mysql2::Client
    private
    def connect(*)
    end
  end
end
