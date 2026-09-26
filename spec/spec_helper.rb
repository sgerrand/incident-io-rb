# frozen_string_literal: true

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
