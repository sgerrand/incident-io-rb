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
    # Bundler loads this through the gemspec before coverage starts.
    skip "lib/incident_io/version.rb"

    path = ->(file) { file.project_filename.delete_prefix("/") }
    generated = %r{\Alib/incident_io/(resources|webhook_events\.rb|audit_log_entries\.rb|models\.rb)}
    group("Core") { |file| path[file].start_with?("lib/") && !path[file].match?(generated) }
    group("Generated") { |file| path[file].match?(generated) }
    group("Generator") { |file| path[file].start_with?("generator/") }

    # Every line and branch is covered, and should stay that way. Generated
    # resources are called by spec/incident_io/generated_operations_spec.rb.
    coverage :line do
      minimum 100, per: group("Core")
      minimum 100, per: group("Generated")
      minimum 100, per: group("Generator")
    end
    coverage :branch do
      minimum 100, per: group("Core")
      minimum 100, per: group("Generator")
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

  # Builds a webhook signing secret ("whsec_" + base64 key) from raw key
  # bytes, so no secret-shaped string appears in the source for scanners to
  # flag.
  def webhook_secret(key)
    "#{IncidentIo::Webhook::SECRET_PREFIX}#{[key].pack("m0")}"
  end

  # A schedule.deleted_v1 webhook body.
  def schedule_deleted_body
    JSON.generate("event_type" => "schedule.deleted_v1", "schedule.deleted_v1" => {"id" => "01S"})
  end

  # Headers as Rack env keys, e.g. "webhook-id" => "HTTP_WEBHOOK_ID".
  def rack_headers(headers)
    headers.transform_keys { |key| "HTTP_#{key.upcase.tr("-", "_")}" }
  end

  # Headers for a webhook body signed with the secret, sent now.
  def signed_webhook_headers(body, secret:, id: "msg_1")
    sent_at = Time.now.to_i
    signature = IncidentIo::Webhook.sign(body, id:, timestamp: sent_at, secret:)
    {"webhook-id" => id, "webhook-timestamp" => sent_at.to_s, "webhook-signature" => "v1,#{signature}"}
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Turns on deprecation warnings for examples tagged :deprecation_warnings.
  config.around(:example, :deprecation_warnings) do |example|
    before = Warning[:deprecated]
    Warning[:deprecated] = true
    example.run
  ensure
    Warning[:deprecated] = before
  end
end
