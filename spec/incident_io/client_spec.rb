# frozen_string_literal: true

require "logger"
require "stringio"

RSpec.describe IncidentIo::Client do
  subject(:client) { described_class.new(api_key: "secret-key") }

  before { allow(client).to receive(:sleep_for) }

  describe ".new" do
    it "raises without an API key" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("INCIDENT_IO_API_KEY", nil).and_return(nil)

      expect { described_class.new }.to raise_error(IncidentIo::ConfigurationError, /INCIDENT_IO_API_KEY/)
    end

    it "reads the API key from the environment" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("INCIDENT_IO_API_KEY", nil).and_return("env-key")
      stub = stub_request(:get, "#{BASE_URL}/v1/identity").with(headers: { "Authorization" => "Bearer env-key" })

      described_class.new.request(:get, "/v1/identity")

      expect(stub).to have_been_requested
    end

    it "does not show the API key in #inspect" do
      expect(client.inspect).not_to include("secret-key")
    end
  end

  describe "#request" do
    it "sends auth, accept and user agent headers" do
      stub = stub_request(:get, "#{BASE_URL}/v2/incidents/abc").with(
        headers: {
          "Authorization" => "Bearer secret-key",
          "Accept" => "application/json",
          "User-Agent" => %r{\Aincident-io-ruby/#{Regexp.escape(IncidentIo::VERSION)} ruby/}
        }
      ).to_return(json_response({ "incident" => { "id" => "abc" } }))

      expect(client.request(:get, "/v2/incidents/abc")).to eq("incident" => { "id" => "abc" })
      expect(stub).to have_been_requested
    end

    it "adds a custom user agent before its own" do
      client = described_class.new(api_key: "k", user_agent: "my-app/1.0")
      stub = stub_request(:get, "#{BASE_URL}/v1/identity").with(headers: { "User-Agent" => %r{\Amy-app/1\.0 incident-io-ruby/} })

      client.request(:get, "/v1/identity")

      expect(stub).to have_been_requested
    end

    it "encodes query params" do
      stub = stub_request(:get, "#{BASE_URL}/v2/incidents")
        .with(query: "page_size=5&status%5Bone_of%5D=a&status%5Bone_of%5D=b")

      client.request(:get, "v2/incidents", query: { page_size: 5, status: { one_of: %w[a b] } })

      expect(stub).to have_been_requested
    end

    it "sends a JSON body" do
      stub = stub_request(:post, "#{BASE_URL}/v2/incidents").with(
        headers: { "Content-Type" => "application/json" },
        body: { "name" => "DB down", "visibility" => "public", "at" => "2024-05-01T12:00:00.000Z" }
      ).to_return(json_response({ "incident" => { "id" => "1" } }, status: 201))

      client.request(:post, "/v2/incidents", body: { name: "DB down", visibility: :public, at: Time.utc(2024, 5, 1, 12) })

      expect(stub).to have_been_requested
    end

    it "returns nil for an empty body" do
      stub_request(:delete, "#{BASE_URL}/v2/schedules/1").to_return(status: 204)

      expect(client.request(:delete, "/v2/schedules/1")).to be_nil
    end

    it "returns non-JSON bodies as strings" do
      stub_request(:get, "#{BASE_URL}/v2/pay_reports/1/download")
        .to_return(status: 200, body: "a,b\n1,2\n", headers: { "Content-Type" => "text/csv" })

      expect(client.request(:get, "/v2/pay_reports/1/download")).to eq("a,b\n1,2\n")
    end

    it "honours per-request options" do
      stub = stub_request(:post, "#{BASE_URL}/v2/heartbeat/src/ping")
        .with(headers: { "Authorization" => "Bearer source-token", "X-Extra" => "1" })

      client.request(:post, "/v2/heartbeat/src/ping", request_options: { api_key: "source-token", headers: { "X-Extra" => "1" } })

      expect(stub).to have_been_requested
    end

    it "rejects unknown per-request options" do
      expect { client.request(:get, "/x", request_options: { nope: 1 }) }
        .to raise_error(ArgumentError, "unknown request option: nope")
    end

    it "raises a typed error with the API's details" do
      stub_request(:get, "#{BASE_URL}/v2/incidents/missing")
        .to_return(json_response(error_body(status: 404, type: "not_found", message: "No incident"), status: 404))

      expect { client.request(:get, "/v2/incidents/missing") }.to raise_error(IncidentIo::NotFoundError) { |e|
        expect(e.status).to eq(404)
        expect(e.request_id).to eq("req_123")
        expect(e.message).to eq("404 not_found: No incident (request_id: req_123)")
      }
    end

    it "maps timeouts to APITimeoutError" do
      stub_request(:get, "#{BASE_URL}/v1/identity").to_timeout

      expect { client.request(:get, "/v1/identity") }.to raise_error(IncidentIo::APITimeoutError)
    end

    it "maps connection failures to APIConnectionError" do
      stub_request(:get, "#{BASE_URL}/v1/identity").to_raise(Errno::ECONNREFUSED)

      expect { client.request(:get, "/v1/identity") }.to raise_error(IncidentIo::APIConnectionError)
    end
  end

  describe "retries" do
    let(:url) { "#{BASE_URL}/v2/incidents" }
    let(:server_error) { json_response(error_body(status: 500, type: "internal_error"), status: 500) }
    let(:ok) { json_response({ "incidents" => [] }) }

    it "retries idempotent requests after 5xx" do
      stub = stub_request(:get, url).to_return(server_error, ok)

      expect(client.request(:get, "/v2/incidents")).to eq("incidents" => [])
      expect(stub).to have_been_requested.twice
      expect(client).to have_received(:sleep_for).once
    end

    it "gives up after max_retries" do
      stub = stub_request(:get, url).to_return(server_error)

      expect { client.request(:get, "/v2/incidents") }.to raise_error(IncidentIo::InternalServerError)
      expect(stub).to have_been_requested.times(3)
    end

    it "honours max_retries per request" do
      stub = stub_request(:get, url).to_return(server_error)

      expect { client.request(:get, "/v2/incidents", request_options: { max_retries: 0 }) }
        .to raise_error(IncidentIo::InternalServerError)
      expect(stub).to have_been_requested.once
    end

    it "does not retry a POST after 5xx" do
      stub = stub_request(:post, url).to_return(server_error)

      expect { client.request(:post, "/v2/incidents", body: {}) }.to raise_error(IncidentIo::InternalServerError)
      expect(stub).to have_been_requested.once
    end

    it "retries a POST marked idempotent" do
      stub = stub_request(:post, url).to_return(server_error, ok)

      client.request(:post, "/v2/incidents", body: { idempotency_key: "k" }, idempotent: true)

      expect(stub).to have_been_requested.twice
    end

    it "does not retry client errors" do
      stub = stub_request(:get, url).to_return(json_response(error_body(status: 422, type: "validation_error"), status: 422))

      expect { client.request(:get, "/v2/incidents") }.to raise_error(IncidentIo::UnprocessableEntityError)
      expect(stub).to have_been_requested.once
    end

    it "retries a rate-limited POST, waiting as long as asked" do
      limited = json_response(error_body(status: 429, type: "rate_limit_reached"), status: 429, headers: { "Retry-After" => "2" })
      stub = stub_request(:post, url).to_return(limited, ok)

      client.request(:post, "/v2/incidents", body: {})

      expect(stub).to have_been_requested.twice
      expect(client).to have_received(:sleep_for).with(2.0)
    end

    it "raises instead of waiting a very long time" do
      limited = json_response(error_body(status: 429, type: "rate_limit_reached"), status: 429, headers: { "Retry-After" => "600" })
      stub = stub_request(:get, url).to_return(limited)

      expect { client.request(:get, "/v2/incidents") }.to raise_error(IncidentIo::RateLimitError)
      expect(stub).to have_been_requested.once
      expect(client).not_to have_received(:sleep_for)
    end

    it "uses exponential backoff when the API gives no hint" do
      stub_request(:get, url).to_return(server_error, server_error, ok)
      delays = []
      allow(client).to receive(:sleep_for) { |s| delays << s }

      client.request(:get, "/v2/incidents")

      expect(delays[0]).to be_between(0.375, 0.5)
      expect(delays[1]).to be_between(0.75, 1.0)
    end

    it "retries idempotent requests after network errors" do
      stub = stub_request(:get, url).to_timeout.then.to_return(ok)

      client.request(:get, "/v2/incidents")

      expect(stub).to have_been_requested.twice
    end

    it "does not retry a POST after a network error" do
      stub = stub_request(:post, url).to_timeout

      expect { client.request(:post, "/v2/incidents", body: {}) }.to raise_error(IncidentIo::APITimeoutError)
      expect(stub).to have_been_requested.once
    end
  end

  describe "logging" do
    it "logs each attempt and redacts query tokens" do
      io = StringIO.new
      client = described_class.new(api_key: "secret-key", logger: Logger.new(io))
      stub_request(:post, %r{/v2/alert_events/http/src}).to_return(status: 202)

      client.request(:post, "/v2/alert_events/http/src", query: { token: "very-secret" }, body: {})

      expect(io.string).to include("POST #{BASE_URL}/v2/alert_events/http/src?token=[REDACTED] -> 202")
      expect(io.string).not_to include("very-secret")
      expect(io.string).not_to include("secret-key")
    end
  end
end
