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
  MAX_LRU_SIZE = 1000

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
      evict_oldest if @table.size >= MAX_LRU_SIZE
    end
  end

  def get(key)
    @lock.synchronize do
      found = @table.delete(key)
      if found
        @table[key] = found
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

  def evict_oldest
    resource = @table.shift
    if resource
      Semian.notify(:lru_hash_cleaned, self, :cleaning, :lru_hash)
      resource.destroy
    end
  end
end
