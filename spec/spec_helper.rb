# frozen_string_literal: true

# Coverage is measured when COVERAGE is set, e.g. `COVERAGE=1 bundle exec
# rspec`. It must start before the library loads.
unless ENV.fetch("COVERAGE", "").empty?
  require "simplecov"

  SimpleCov.start do
    enable_coverage :branch
    cover "{lib,generator}/**/*.rb"
    # Models are one Model.define call each with no logic of their own; which
    # ones load only says which the specs happen to touch.
    skip "lib/incident_io/models/"

    path = ->(file) { file.project_filename.delete_prefix("/") }
    generated = %r{\Alib/incident_io/(resources|webhook_events\.rb|audit_log_entries\.rb|models\.rb)}
    group("Core") { |file| path[file].start_with?("lib/") && !path[file].match?(generated) }
    group("Generated") { |file| path[file].match?(generated) }
    group("Generator") { |file| path[file].start_with?("generator/") }

    # Set a little below what the specs reach today. Generated code has no
    # minimum: most of it counts as covered just by loading.
    coverage :line do
      minimum 95, per: group("Core")
      minimum 93, per: group("Generator")
    end
    coverage :branch do
      minimum 85, per: group("Core")
      minimum 75, per: group("Generator")
    end
  end
end

require "incident_io"
require "webmock/rspec"

WebMock.disable_net_connect!

BASE_URL = "https://api.incident.io"

module SpecHelpers
  def json_response(body, status: 200, headers: {})
    {status:, body: JSON.generate(body), headers: {"Content-Type" => "application/json"}.merge(headers)}
  end

  def error_body(status:, type:, message: "boom", request_id: "req_123", **extra)
    {"status" => status, "type" => type, "request_id" => request_id,
     "errors" => [{"code" => type, "message" => message}]}.merge(extra)
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
