class LRUHash
  extend Forwardable
  def_delegators :@table, :size, :count, :empty?
  attr_reader :table, :minimum_time_in_lru

  class NoopMutex
    def synchronize(*)
      yield
    end
  end

  [:keys, :clear].each do |attribute|
    define_method :"#{attribute}" do
      @lock.synchronize { @table.public_send(attribute) }
    end
  end

  def initialize(minimum_time_in_lru:)
    @minimum_time_in_lru = minimum_time_in_lru
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
    @lock.synchronize do
      unused_resources.take(2).each do |resource|
        break if resource.updated_at + minimum_time_in_lru > Time.now

        resource = @table.delete(resource.name)
        if resource
          resource.destroy
        end
      end
    end
  end

  def unused_resources
    @table.map { |_, resource| resource unless resource.in_use? }.compact
  end
end
