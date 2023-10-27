# frozen_string_literal: true

require "bundler/gem_tasks"

# ==========================================================
# Packaging
# ==========================================================

GEMSPEC = eval(File.read("semian.gemspec")) # rubocop:disable Security/Eval

require "rubygems/package_task"
Gem::PackageTask.new(GEMSPEC) do |_pkg|
end

# ==========================================================
# Ruby Extension
# ==========================================================

$LOAD_PATH.unshift(File.expand_path("../lib", __FILE__))
require "semian/platform"
if Semian.sysv_semaphores_supported?
  require "rake/extensiontask"
  Rake::ExtensionTask.new("semian", GEMSPEC) do |ext|
    ext.ext_dir = "ext/semian"
    ext.lib_dir = "lib/semian"
  end
  desc "Build gem"
  task build: :compile
else
  desc "Build gem"
  task :build do # rubocop:disable Rake/DuplicateTask
  end
end

# ==========================================================
# Testing
# ==========================================================

require "rake/testtask"
Rake::TestTask.new("test") do |t|
  t.libs = ["lib", "test"]
  t.pattern = "test/**/*_test.rb"
  t.warning = false
  if ENV["CI"] || ENV["VERBOSE"]
    t.options = "-v"
  end
end

namespace :test do
  Rake::TestTask.new("semian") do |t|
    t.description = "Run common library tests without adapters"
    t.libs = ["lib", "test"]
    t.pattern = "test/*_test.rb"
    t.warning = false
    if ENV["CI"] || ENV["VERBOSE"]
      t.options = "-v"
    end
  end

  desc "Parallel tests. Use TEST_WORKERS and TEST_WORKER_NUM. TEST_WORKER_NUM in range from 1..TEST_WORKERS"
  task :parallel do
    workers = ENV.fetch("TEST_WORKERS", 1).to_i
    worker = ENV.fetch("TEST_WORKER_NUM", 1).to_i
    buckets = Array.new(workers) { [] }

    # Fill the buckets
    i = 0
    files = Dir["test/*_test.rb"].entries.sort { |f| File.size(f) }
    files.each do |f|
      i = 0 if buckets.size == i
      buckets[i] << f
      i += 1
    end

    if worker < 1 || worker > workers
      raise "TEST_WORKER_NUM is not correct: #{worker}. " \
        "Check that it greater or equal 1 and less or equal TEST_WORKERS: #{workers}"
    end

    files = buckets[worker - 1].join(" ")
    args = "-Ilib:test -r 'rake/rake_test_loader.rb' #{files} -v #{ENV.fetch("TESTOPTS", "")}"
    ruby args do |ok, status|
      if !ok && status.respond_to?(:signaled?) && status.signaled?
        raise SignalException, status.termsig
      elsif !ok
        status  = "Command failed with status (#{status.exitstatus})"
        details = ": [ruby #{args}]"
        message = status + details
        raise message
      end
    end
  end
end

# ==========================================================
# Documentation
# ==========================================================

require "rdoc/task"
RDoc::Task.new do |rdoc|
  rdoc.rdoc_files.include("lib/*.rb", "ext/semian/*.c")
end

# ==========================================================
# Examples
# ==========================================================

namespace :examples do
  desc "Run examples for net_http"
  task :net_http do
    Dir["examples/net_http/*.rb"].entries.each do |f|
      ruby f do |ok, status|
        if !ok && status.respond_to?(:signaled?) && status.signaled?
          raise SignalException, status.termsig
        elsif !ok
          status  = "Command failed with status (#{status.exitstatus})"
          details = ": [ruby #{f}]"
          message = status + details
          raise message
        end
      end
    end
  end

  desc "Run examples for activerecord-trilogy-adapter"
  task :activerecord_trilogy_adapter do
    Dir["examples/activerecord_trilogy_adapter/*.rb"].entries.each do |f|
      ruby f do |ok, status|
        if !ok && status.respond_to?(:signaled?) && status.signaled?
          raise SignalException, status.termsig
        elsif !ok
          status  = "Command failed with status (#{status.exitstatus})"
          details = ": [ruby #{f}]"
          message = status + details
          raise message
        end
      end
    end
  end
end

desc "Run examples"
task examples: ["examples:net_http", "examples:activerecord_trilogy_adapter"]

task default: :build
task default: :test # rubocop:disable Rake/DuplicateTask

desc "Generate flamegrpahs for different versions"
task :flamegraph do
  script = "scripts/benchmarks/flamegraph.rb"
  flamegraph_parse_command = "flamegraph.pl --countname=ms --width=1400"

  %x(ruby #{script} | #{flamegraph_parse_command} > without_semian.svg)
  ["v0.15.0", "v0.16.0", "v0.17.0", "main"].each do |ver|
    %x(WITH_CIRCUIT_BREAKER_ENABLED=1 SEMIAN_VERSION=#{ver} ruby #{script} \
        | #{flamegraph_parse_command} > semian_#{ver}_enabled.svg)
  end
end

desc "Run benchmarks for specific versions"
task :benchmark do
  ["v0.15.0", "v0.16.0", "v0.17.0", "main"].each do |ver|
    ruby "scripts/benchmarks/net_http_acquire_benchmarker.rb SEMIAN_VERSION=#{ver}"
    ruby "scripts/benchmarks/lru_benchmarker.rb SEMIAN_VERSION=#{ver}"
  end
end
