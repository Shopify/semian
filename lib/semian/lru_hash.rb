class LRUHash
  # This LRU (Least Recently Used) hash will allow
  # the cleaning of resources as time goes on.
  # The goal is to remove the least recently used resources
  # everytime we set a new resource. A default window of
  # 5 minutes will allow empty item to stay in the hash
  # for a maximum of 5 minutes
  extend Forwardable
  def_delegators :@table, :size, :count, :empty?, :values
  attr_reader :table
  MINIMUM_TIME_IN_LRU = 300

  class NoopMutex
    def synchronize(*)
      yield
    end

    def try_lock
      true
    end

    def unlock
      true
    end

    def locked?
      true
    end
  end

  [:keys, :clear].each do |attribute|
    define_method :"#{attribute}" do
      @lock.synchronize { @table.public_send(attribute) }
    end
  end

  def initialize
    @table = {}
    @lock =
      if Semian.thread_safe?
        Mutex.new
      else
        NoopMutex.new
      end
  end

  def set(key, resource)
    @lock.synchronize do
      @table.delete(key)
      @table[key] = resource
      resource.updated_at = Time.now
    end
    clear_unused_resources
  end

  # This method uses the property that "Hashes enumerate their values in the
  # order that the corresponding keys were inserted." Deleting a key and
  # re-inserting it effectively moves it to the front of the cache.
  # Update the `updated_at` field so we can use it later do decide if the
  # resource is "in use".
  def get(key)
    @lock.synchronize do
      found = @table.delete(key)
      if found
        @table[key] = found
        found.updated_at = Time.now
      end
      found
    end
  end

  def delete(key)
    @lock.synchronize do
      @table.delete(key)
    end
  end

  def []=(key, resource)
    set(key, resource)
  end

  def [](key)
    get(key)
  end

  private

  def clear_unused_resources
    return unless @lock.try_lock
    # Clears resources that have not been used in the last 5 minutes.
    begin
      timer_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      payload = {
          size: @table.size,
          examined: 0,
          cleared: 0,
          elapsed: nil,
      }

      stop_time = Time.now - MINIMUM_TIME_IN_LRU # Don't process resources updated after this time
      @table.each do |_, resource|
        payload[:examined] += 1

        # The update times of the resources in the LRU are monotonically increasing,
        # time, so we can stop looking once we find the first resource with an
        # update time after the stop_time.
        break if resource.updated_at > stop_time

        # TODO(michaelkipper): Should this be a flag?
        next if resource.in_use?

        resource = @table.delete(resource.name)
        if resource
          payload[:cleared] += 1
          resource.destroy
        end
      end

      payload[:elapsed] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - timer_start
      Semian.notify(:lru_hash_gc, self, nil, nil, payload)
    ensure
      @lock.unlock
    end
  end
end
