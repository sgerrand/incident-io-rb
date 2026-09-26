require_relative "lib/incident_io/version"

Gem::Specification.new do |s|
  s.name        = "incident-io"
  s.version     = IncidentIo::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Sasha Gerrand"]
  s.email       = ["incident-io+rubygems@sgerrand.dev"]
  s.homepage    = "https://github.com/sgerrand/incident-io-rb"
  s.summary     = "incident.io Ruby API client"
  s.description = "A Ruby API client for interacting with the incident.io API."
  s.license     = "MIT"
  s.required_ruby_version = ">= 3.3"

  s.metadata = {
    "source_code_uri" => s.homepage,
    "bug_tracker_uri" => "#{s.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  s.cert_chain  = ['certs/sgerrand.pem']
  s.signing_key = File.expand_path("~/.ssh/gem-private_key.pem") if $0 =~ /gem\z/

  s.files         = Dir['README.md', 'lib/**/*.rb']
  s.executables   = []
  s.require_paths = ["lib"]
end
