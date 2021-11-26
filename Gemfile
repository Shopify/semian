source 'https://rubygems.org'

if RUBY_VERSION >= '2.7'
  # Hack to get grpc and it's dependencies to install on Ruby 2.7
  module BundlerHack
    def __materialize__
      if name == 'grpc' || name == 'google-protobuf'
        Bundler.settings.temporary(force_ruby_platform: true) do
          super
        end
      else
        super
      end
    end
  end
  Bundler::LazySpecification.prepend(BundlerHack)
end

gemspec

group :development, :test do
  gem 'rubocop'
end
