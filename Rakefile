# frozen_string_literal: true

require "bundler/gem_tasks"
require "rubocop/rake_task"
RuboCop::RakeTask.new do |task|
  task.requires << "rubocop-minitest"
  task.requires << "rubocop-rake"
end

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
  t.pattern = "test/*_test.rb"
  t.warning = false
  if ENV["CI"] || ENV["VERBOSE"]
    t.options = "-v"
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
