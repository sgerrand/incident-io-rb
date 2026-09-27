source "https://rubygems.org"

gemspec

group :development, :test do
  gem "logger"
  gem "rake", "~> 13.0"
  gem "rbs", "~> 4.2", require: false
  gem "rspec", "~> 3.13"
  gem "simplecov", "~> 1.3", require: false
  gem "webmock", "~> 3.23"
end

# Type checking needs Ruby 3.3+ and many gems, so CI only installs it for
# the type check job.
group :typecheck do
  gem "steep", "~> 2.1"
end

# Linting with Standard, which runs on RuboCop. CI only installs it for the
# lint job.
group :lint do
  gem "rubocop"
  gem "rubocop-yard", "~> 1.3"
  gem "standard", "~> 1.56"
end

# Checking YARD docs with Yardstick. CI only installs it for the Yardstick
# job. YARD's legacy parser needs irb, which Ruby 4.0 no longer includes.
group :docs do
  gem "irb"
  gem "yardstick", "~> 0.9.9"
end
