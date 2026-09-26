# frozen_string_literal: true

RSpec.describe IncidentIo::APIError do
  def response(status, body = nil, headers = {})
    IncidentIo::Response.new(
      status:,
      headers: {"content-type" => "application/json"}.merge(headers),
      body: body && JSON.generate(body)
    )
  end

  {
    400 => IncidentIo::BadRequestError,
    401 => IncidentIo::AuthenticationError,
    403 => IncidentIo::PermissionDeniedError,
    404 => IncidentIo::NotFoundError,
    408 => IncidentIo::RequestTimeoutError,
    409 => IncidentIo::ConflictError,
    422 => IncidentIo::UnprocessableEntityError,
    429 => IncidentIo::RateLimitError,
    500 => IncidentIo::InternalServerError,
    503 => IncidentIo::InternalServerError,
    412 => IncidentIo::APIError
  }.each do |status, klass|
    it "maps #{status} to #{klass}" do
      expect(described_class.from_response(response(status))).to be_an_instance_of(klass)
    end
  end

  it "reads the ErrorResponse body" do
    body = {
      "type" => "validation_error",
      "status" => 422,
      "request_id" => "req_1",
      "errors" => [{
        "code" => "invalid_value",
        "message" => "Must be a URL",
        "source" => {"field" => "default_call_url", "pointer" => "/settings/default_call_url"},
        "metadata" => {"a" => "b"}
      }]
    }

    error = described_class.from_response(response(422, body))

    expect(error.type).to eq("validation_error")
    expect(error.request_id).to eq("req_1")
    expect(error.errors.first).to have_attributes(
      code: "invalid_value", message: "Must be a URL", field: "default_call_url",
      pointer: "/settings/default_call_url", metadata: {"a" => "b"}
    )
    expect(error.message).to eq("422 validation_error: Must be a URL (request_id: req_1)")
  end

  it "copes with a non-JSON body" do
    error = described_class.from_response(IncidentIo::Response.new(status: 502, headers: {}, body: "Bad Gateway"))

    expect(error.body).to eq("Bad Gateway")
    expect(error.errors).to eq([])
    expect(error.message).to eq("502")
  end

  describe "#retry_after" do
    it "reads a Retry-After header in seconds" do
      error = described_class.from_response(response(429, nil, "retry-after" => "3"))

      expect(error.retry_after).to eq(3.0)
    end

    it "reads a Retry-After header as an HTTP date" do
      at = (Time.now + 5).httpdate
      error = described_class.from_response(response(429, nil, "retry-after" => at))

      expect(error.retry_after).to be_within(1.5).of(5)
    end

    it "falls back to rate_limit.retry_after in the body" do
      body = {"rate_limit" => {"name" => "api_key", "limit" => 100, "remaining" => 0,
                               "retry_after" => (Time.now + 10).utc.iso8601}}
      error = described_class.from_response(response(429, body))

      expect(error.rate_limit).to have_attributes(name: "api_key", limit: 100, remaining: 0)
      expect(error.retry_after).to be_within(1.5).of(10)
    end

    it "is never negative" do
      body = {"rate_limit" => {"retry_after" => "2020-01-01T00:00:00Z"}}

      expect(described_class.from_response(response(429, body)).retry_after).to eq(0.0)
    end

    it "is nil when the API gives no hint" do
      expect(described_class.from_response(response(429)).retry_after).to be_nil
    end
  end
end
