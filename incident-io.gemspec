Gem::Specification.new do |s|
  s.name        = "incident-io"
  s.version     = "0.0.0-alpha"
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Sasha Gerrand"]
  s.email       = ["incident-io+rubygems@sgerrand.dev"]
  s.homepage    = "https://github.com/sgerrand/incident-io"
  s.summary     = "incident.io Ruby API client"
  s.description = "This is the Ruby API client for the incident.io API."
  s.license     = "MIT"
  s.required_ruby_version = ">= 1.9"

  s.cert_chain  = ['certs/sgerrand.pem']
  s.signing_key = File.expand_path("~/.ssh/gem-private_key.pem") if $0 =~ /gem\z/

  s.files         = Dir['Gemfile', 'README.md', 'lib/**/*.rb']
  s.test_files    = Dir['spec/**/*.rb']
  s.executables   = []
  s.require_paths = ["lib"]
end
