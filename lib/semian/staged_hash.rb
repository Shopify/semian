class StagedHash
  MAX_LRU_SIZE = 1000

  def initialize(max_lru_size: 0)
    @unused_hash = {}
    @in_use_hash = {}
    @lock =
      if Semian.thread_safe?
        Mutex.new
      else
        LRUHash::NoopMutex.new
      end
  end

  def set(key, resource)
    @lock.synchronize do
      @unused_hash.delete(key)
      @unused_hash[key] = resource
      evict_oldest if @unused_hash.size >= MAX_LRU_SIZE
    end
  end

  def get(key)
    @lock.synchronize do
      found = @unused_hash.delete(key)
      if found
        @unused_hash[key] = found
        found
      else
        @in_use_hash[key]
      end
    end
  end

  def delete(key)
    @lock.synchronize do
      found = @unused_hash.delete(key)
      if found
        found
      else
        @in_use_hash.delete(key)
      end
    end
  end

  def []=(key, resource)
    set(key, resource)
  end

  def [](key)
    get(key)
  end

  def mark_in_use(key)
    found = @unused_hash.delete(key)
    @in_use_hash[key] = found
  end

  def mark_unused(key)
    found = @in_use_hash.delete(key)
    set(key, resource)
  end

  private

  def evict_oldest
    resource = @table.shift
    if resource
      Semian.notify(:lru_hash_cleaned, self, :cleaning, :lru_hash)
      resource.destroy
    end
  end
end

