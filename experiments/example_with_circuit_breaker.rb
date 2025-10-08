# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

resource = Semian::Experiments::ExperimentalResource.new(
  name: "protected_service",
  endpoints_count: 200,
  min_latency: 0.01,
  max_latency: 10,
  distribution: {
    type: :log_normal,
    mean: 1,
    std_dev: 0.1,
  },
  error_rate: 0.01, # 1% baseline error rate
  timeout: 5, # 5 seconds timeout
  semian: {
    success_threshold: 2,
    error_threshold: 3,
    error_threshold_timeout: 20,
    error_timeout: 15,
    bulkhead: false,
  },
)

outcomes = {}

done = false

Thread.new do
  until done
    sleep(0.1) # Don't send more than 10 requests per second
    current_sec = outcomes[Time.now.to_i] ||= {
      success: 0,
      circuit_open: 0,
      error: 0,
    }
    begin
      resource.request(rand(resource.endpoints_count))
      puts "✓ Success"
      current_sec[:success] += 1
    rescue Semian::Experiments::ExperimentalResource::CircuitOpenError => e
      puts "⚡ Circuit Open - #{e.message}"
      current_sec[:circuit_open] += 1
    rescue Semian::Experiments::ExperimentalResource::RequestError, Semian::Experiments::ExperimentalResource::TimeoutError => e
      puts "✗ Error"
      current_sec[:error] += 1
    end
  end
end

sleep 10

puts "Setting error rate to 0.5"
resource.set_error_rate(0.5)

sleep 10

puts "Resetting error rate to 0.01"
resource.set_error_rate(0.01)

sleep 10

done = true

puts "Generating graph showing success, circuit open, and error rates over time, (bucketed by 1 second)..."
require "gruff"

graph = Gruff::Line.new
graph.title = "Outcomes"
graph.x_axis_label = "Time"
graph.y_axis_label = "Count"

graph.hide_dots = true
graph.line_width = 3

graph.data("Success", outcomes.map { |_, data| data[:success] })
graph.data("Circuit Open", outcomes.map { |_, data| data[:circuit_open] })
graph.data("Error", outcomes.map { |_, data| data[:error] })

graph.write("example_output.png")

puts "Graph saved to outcomes.png"
