class LRUHash
  # This LRU (Least Recently Used) hash will allow
  # the cleaning of resources as time goes.
  # The  goal is to remove the least recently used resources
  # everytime we set a new resource. A default window of
  # 5 minutes will allow empty item to stay in the hash
  # for a maximum of 5 minutes
  extend Forwardable
  def_delegators :@table, :size, :count, :empty?
  attr_reader :table, :minimum_time_in_lru
  MINIMUM_TIME_IN_LRU = 300

  class NoopMutex
    def synchronize(*)
      yield
    end

    def locked?
      false
    end
  end

  [:keys, :clear].each do |attribute|
    define_method :"#{attribute}" do
      @lock.synchronize { @table.public_send(attribute) }
    end
  end

  def initialize
    @minimum_time_in_lru = MINIMUM_TIME_IN_LRU
    @table = {}
    @lock =
      if Semian.thread_safe?
        Mutex.new
      else
        NoopMutex.new
      end
  end

  def set(key, resource)
    delete(key)
    @lock.synchronize do
      @table[key] = resource
    end
    clear_unused_resources
    resource.updated_at = Time.now
  end

  def get(key)
    found = delete(key)
    @lock.synchronize do
      if found
        @table[key] = found
      end
    end
    @table[key]
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
    # Clears resources that have not been used
    # in the last 5 minutes.
    return if @lock.locked?
    @lock.synchronize do
      @table.each do |_, resource|
        break if resource.updated_at + minimum_time_in_lru > Time.now
        next if resource.in_use?

        resource = @table.delete(resource.name)
        if resource
          resource.destroy
        end
      end
    end
  end
end
