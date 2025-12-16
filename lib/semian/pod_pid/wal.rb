# frozen_string_literal: true

require "digest/crc32"
require "msgpack"
require "fileutils"

# The WAL uses the binary format described below:
#
# +----------+---------------+-----------------+------------------+-------+-------+
# | CRC (4B) | Key Size (2B) | Value Size (2B) | Timestamp (8B)   | Key   | Value |
# +----------+---------------+-----------------+------------------+-------+-------+
#
# CRC (4 bytes)
#   - CRC32 checksum computed over the payload (everything after CRC)
#   - Used to detect corrupted entries during replay
#   - Packed as big-endian unsigned 32-bit integer (N)
#
# Key Size (2 bytes)
#   - Length of the Key field in bytes
#   - Packed as big-endian unsigned 16-bit integer (S>)
#   - Max key size: 65,535 bytes
#
# Value Size (2 bytes)
#   - Length of the Value field in bytes
#   - Packed as big-endian unsigned 16-bit integer (S>)
#   - Max value size: 65,535 bytes
#
# Timestamp (8 bytes)
#   - Microseconds since Unix epoch when entry was written
#   - Packed as big-endian unsigned 64-bit integer (Q>)
#   - Used to determine which entry is latest per resource
#
# Key (variable)
#   - Resource name as UTF-8 encoded string (e.g., "mysql", "redis_cache")
#
# Value (variable)
#   - PID state serialized with MessagePack
#   - Contains: rejection_rate, integral, smoother_value, observation_count
#
module Semian
  module PodPID
    class WAL
      DEFAULT_PATH = "/tmp/semian_pid.wal"

      attr_reader :path

      def initialize(path = DEFAULT_PATH)
        @path = path
        @mutex = Mutex.new
        ensure_directory_exists
      end

      def write(resource, state)
        @mutex.synchronize do
          key = resource.to_s.encode("UTF-8")
          value = MessagePack.pack(state)
          timestamp = (Time.now.to_f * 1_000_000).to_i

          payload = [key.bytesize, value.bytesize, timestamp].pack("S>S>Q>") + key + value
          crc = Digest::CRC32.checksum(payload)

          File.open(@path, "ab") do |f|
            f.write([crc].pack("N") + payload)
          end
        end
      end

      def replay
        return 0 unless File.exist?(@path)

        entries_by_resource = {}

        @mutex.synchronize do
          File.open(@path, "rb") do |f|
            until f.eof?
              break unless (entry = read_entry(f))

              resource, state, _timestamp = entry
              entries_by_resource[resource] = state
            end
          end
        end

        entries_by_resource.each do |resource, state|
          yield(resource, state) if block_given?
        end

        entries_by_resource.size
      end

      def truncate
        @mutex.synchronize do
          File.truncate(@path, 0) if File.exist?(@path)
        end
      end

      private

      def read_entry(file)
        header = file.read(4)
        return unless header&.bytesize == 4

        crc = header.unpack1("N")

        sizes_and_ts = file.read(12)
        return unless sizes_and_ts&.bytesize == 12

        key_size, value_size, timestamp = sizes_and_ts.unpack("S>S>Q>")

        key = file.read(key_size)
        value = file.read(value_size)
        return unless key&.bytesize == key_size && value&.bytesize == value_size

        payload = sizes_and_ts + key + value
        expected_crc = Digest::CRC32.checksum(payload)

        return unless crc == expected_crc

        [key, MessagePack.unpack(value, symbolize_keys: true), timestamp]
      end

      def ensure_directory_exists
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
      end
    end
  end
end
