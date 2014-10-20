task :default => :test

# ==========================================================
# Packaging
# ==========================================================

GEMSPEC = eval(File.read('semian.gemspec'))

require 'rubygems/package_task'
Gem::PackageTask.new(GEMSPEC) do |pkg|
end

# ==========================================================
# Ruby Extension
# ==========================================================

$:.unshift File.expand_path("../lib", __FILE__)
require 'semian/platform'
if Semian.supported_platform?
  require 'rake/extensiontask'
  Rake::ExtensionTask.new('semian', GEMSPEC) do |ext|
    ext.ext_dir = 'ext/semian'
    ext.lib_dir = 'lib/semian'
  end
  task :build => :compile
else
  task :build do; end
end

# ==========================================================
# Testing
# ==========================================================

require 'rake/testtask'
Rake::TestTask.new 'test' do |t|
  t.test_files = if Semian.supported_platform?
    FileList['test/test_semian.rb']
  else
    FileList['test/test_unsupported.rb']
  end
end
task :test => :build

# ==========================================================
# Documentation
# ==========================================================
require 'rdoc/task'
RDoc::Task.new do |rdoc|
  rdoc.rdoc_files.include("lib/*.rb", "ext/semian/*.c")
end
