source "https://rubygems.org"

gemspec

group :development, :test do
  gem "logger"
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"
  gem "webmock", "~> 3.23"
end

# Type checking needs Ruby 3.3+ and many gems, so CI only installs it for
# the type check job.
group :typecheck do
  gem "steep", "~> 2.1"
end
