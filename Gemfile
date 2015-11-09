source 'https://rubygems.org'
gemspec

group :debug do
  gem 'byebug'
end

group :development, :test do
  gem 'toxiproxy', github: 'Shopify/toxiproxy-ruby', ref: 'f0c5d0bebca01180e2cfd5234e3d18affefbc670', require: 'toxiproxy'
  gem 'rubocop', '~> 0.34.2'
end
