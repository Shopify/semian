# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "semian"

smoother = Semian::SimpleExponentialSmoother.new(
  cap_value: 0.1,
  initial_value: 0.05,
  observations_per_minute: 60,
)

observation = []
smoother_value = []

start_time = Time.now

prep_duration = 1800

prep_duration.times do |i|
  observation << [0.05, start_time + i]
  smoother.add_observation(observation.last[0])
  smoother_value << [smoother.forecast, start_time + i]
end

update_duration = 3600

update_duration.times do |i|
  observation << [0.025, start_time + i + prep_duration]
  smoother.add_observation(observation.last[0])
  smoother_value << [smoother.forecast, start_time + i + prep_duration]
end

experiment_duration = prep_duration + update_duration

require "gruff"

# Aggregate data into buckets for detailed visualization
bucket_size = 1
num_buckets = experiment_duration

graph = Gruff::Line.new
graph.x_axis_label = "Time (minutes)"
graph.y_axis_label = "Error Rate vs Smoother value"
graph.hide_dots = true
graph.line_width = 3
graph.y_axis_increment = 0.01
graph.marker_font_size = 12
graph.labels = (experiment_duration / (60 * 5) + 1).times.map { |i| [i * 60 * 5, "#{i * 5}m"] }.to_h

graph.data("Error Rate", observation.map { |d| d[0] })
graph.data("Smoother Value", smoother_value.map { |d| d[0] })

main_graph_path = File.join("smoother_lower_high_conf.png")
graph.write(main_graph_path)
puts "Graph saved to #{main_graph_path}"
