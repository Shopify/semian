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
    t.pattern = "test/**/*_test.rb"
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

task default: :build
task default: :test # rubocop:disable Rake/DuplicateTask
