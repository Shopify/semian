# frozen_string_literal: true

module BackgroundHelper
  def after_setup
    @_threads = []
  end

  def before_teardown
    @_threads.each(&:kill)
    @_threads.each(&:join)
    @_threads = nil
  end

  private

  def background(&block)
    thread = Thread.new(&block)
    thread.report_on_exception = false
    @_threads << thread
    thread.join(0.1)
    thread
  end

  def yield_to_background
    @_threads.each(&:join)
  end
end
