# frozen_string_literal: true

require "rubygems"
require "bundler/setup"
require "minitest/autorun"
require "tempfile"
require "digest/crc32"
require "msgpack"

require_relative "../../lib/semian/pod_pid/wal"

module Semian
  module PodPID
    class WALTest < Minitest::Test
      def setup
        @temp_file = Tempfile.new("semian_wal_test")
        @wal_path = @temp_file.path
        @temp_file.close
        File.delete(@wal_path) if File.exist?(@wal_path)
        @wal = WAL.new(@wal_path)
      end

      def teardown
        File.delete(@wal_path) if File.exist?(@wal_path)
        @temp_file&.unlink
      end

      def test_write_and_replay_single_entry
        state = { rejection_rate: 0.25, integral: 1.5 }
        @wal.write("mysql", state)

        entries = []
        @wal.replay { |resource, s| entries << [resource, s] }

        assert_equal(1, entries.size)
        assert_equal("mysql", entries[0][0])
        assert_equal(0.25, entries[0][1][:rejection_rate])
        assert_equal(1.5, entries[0][1][:integral])
      end

      def test_replay_returns_last_entry_per_resource
        @wal.write("mysql", { rejection_rate: 0.1, integral: 0.5 })
        @wal.write("redis", { rejection_rate: 0.2, integral: 1.0 })
        @wal.write("mysql", { rejection_rate: 0.3, integral: 1.5 })

        entries = {}
        @wal.replay { |resource, state| entries[resource] = state }

        assert_equal(2, entries.size)
        assert_equal(0.3, entries["mysql"][:rejection_rate])
        assert_equal(1.5, entries["mysql"][:integral])
        assert_equal(0.2, entries["redis"][:rejection_rate])
        assert_equal(1.0, entries["redis"][:integral])
      end

      def test_truncate_clears_log
        @wal.write("mysql", { rejection_rate: 0.5 })
        @wal.truncate

        count = @wal.replay { |_r, _s| }

        assert_equal(0, count)
      end

      def test_binary_format_structure
        state = { rejection_rate: 0.25, integral: 1.5 }
        @wal.write("mysql", state)

        File.open(@wal_path, "rb") do |f|
          crc = f.read(4).unpack1("N")
          key_size = f.read(2).unpack1("S>")
          value_size = f.read(2).unpack1("S>")
          timestamp = f.read(8).unpack1("Q>")
          key = f.read(key_size)
          value_bytes = f.read(value_size)

          assert_equal(5, key_size)
          assert_operator(value_size, :>, 0)
          assert_operator(timestamp, :>, 0)
          assert_equal("mysql", key)

          value = MessagePack.unpack(value_bytes, symbolize_keys: true)

          assert_equal(0.25, value[:rejection_rate])
          assert_equal(1.5, value[:integral])

          payload = [key_size, value_size, timestamp].pack("S>S>Q>") + key + value_bytes

          assert_equal(Digest::CRC32.checksum(payload), crc)
          assert(f.eof?)
        end
      end

      def test_corrupted_entry_is_skipped
        @wal.write("mysql", { rejection_rate: 0.25 })
        File.open(@wal_path, "r+b") { |f| f.write([0xDEADBEEF].pack("N")) }

        entries = []
        @wal.replay { |resource, state| entries << [resource, state] }

        assert_equal(0, entries.size)
      end

      def test_empty_file_replay_returns_zero
        count = @wal.replay { |_r, _s| }

        assert_equal(0, count)
      end

      def test_replay_without_block_returns_count
        @wal.write("mysql", { rejection_rate: 0.1 })
        @wal.write("redis", { rejection_rate: 0.2 })

        count = @wal.replay

        assert_equal(2, count)
      end
    end
  end
end
