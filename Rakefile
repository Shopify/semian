require 'bundler/gem_tasks'
begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new
rescue LoadError
end

# ==========================================================
# Packaging
# ==========================================================

GEMSPEC = eval(File.read('semian.gemspec'))

require 'rubygems/package_task'
Gem::PackageTask.new(GEMSPEC) do |_pkg|
end

# ==========================================================
# Ruby Extension
# ==========================================================

$LOAD_PATH.unshift File.expand_path("../lib", __FILE__)
require 'semian/platform'
if Semian.sysv_semaphores_supported?
  require 'rake/extensiontask'
  Rake::ExtensionTask.new('semian', GEMSPEC) do |ext|
    ext.ext_dir = 'ext/semian'
    ext.lib_dir = 'lib/semian'
  end
  Rake::ExtensionTask.new('semian_cb_data', GEMSPEC) do |ext|
    ext.ext_dir = 'ext/semian_cb_data'
    ext.lib_dir = 'lib/semian_cb_data'
  end
  task :build => :compile
else
  task :build do
  end
end

# ==========================================================
# Testing
# ==========================================================

require 'rake/testtask'
Rake::TestTask.new 'test' do |t|
  t.libs = %w(lib test)
  t.pattern = "test/*_test.rb"
end
task test: :build

# ==========================================================
# Documentation
# ==========================================================
require 'rdoc/task'
RDoc::Task.new do |rdoc|
  rdoc.rdoc_files.include("lib/*.rb", "ext/semian/*.c",  "ext/semian_cb_data/*.c")
end

task default: :test
task default: :rubocop
