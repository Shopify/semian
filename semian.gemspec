Gem::Specification.new do |s|
  s.name = 'semian'
  s.version = '0.0.1'
  s.summary = 'SysV semaphore based library for shared resource control'
  s.description = <<-DOC
    A Ruby C extention that is used to control access to shared resources
    across process boundaries.
  DOC
  s.homepage = 'https://github.com/csfrancis/semian'
  s.authors = 'Scott Francis'
  s.email   = 'scott.francis@shopify.com'
  s.license = 'MIT'

  s.files = `git ls-files`.split("\n")
  s.extensions = ['ext/semian/extconf.rb']
  s.add_development_dependency 'rake-compiler', '~> 0.9'
end
