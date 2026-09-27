# frozen_string_literal: true

require "stringio"

RSpec.describe IncidentIo::Webhook::Middleware do
  let(:secret) { "#{IncidentIo::Webhook::SECRET_PREFIX}#{["middleware test key"].pack("m0")}" }
  let(:body) { JSON.generate("event_type" => "schedule.deleted_v1", "schedule.deleted_v1" => {"id" => "01S"}) }
  let(:app_calls) { [] }
  let(:app) { ->(env) { app_calls << env && [200, {}, ["from app"]] } }

  def signed_env(body: self.body, path: "/incident_io/webhooks", method: "POST", input: StringIO.new(body))
    sent_at = Time.now.to_i
    signature = IncidentIo::Webhook.sign(body, id: "msg_1", timestamp: sent_at, secret:)
    {
      "REQUEST_METHOD" => method, "PATH_INFO" => path, "rack.input" => input,
      "HTTP_WEBHOOK_ID" => "msg_1", "HTTP_WEBHOOK_TIMESTAMP" => sent_at.to_s, "HTTP_WEBHOOK_SIGNATURE" => "v1,#{signature}"
    }
  end

  it "calls the block with the event and replies 204" do
    events = []
    middleware = described_class.new(app, secret:) { |event| events << event }

    expect(middleware.call(signed_env)).to eq([204, {}, []])
    expect(events.map { |e| [e.id, e.type, e.data.id] }).to eq([["msg_1", "schedule.deleted_v1", "01S"]])
    expect(app_calls).to be_empty
  end

  it "without a block, passes the event on to the app in the env" do
    status, _, response = described_class.new(app, secret:).call(signed_env)

    expect([status, response]).to eq([200, ["from app"]])
    expect(app_calls.first[described_class::ENV_KEY]).to have_attributes(type: "schedule.deleted_v1")
  end

  it "passes other requests through untouched" do
    middleware = described_class.new(app, secret:) { raise "should not be called" }

    middleware.call(signed_env(path: "/other"))
    middleware.call(signed_env(method: "GET"))

    expect(app_calls.size).to eq(2)
    expect(app_calls).to all(satisfy { |env| !env.key?(described_class::ENV_KEY) })
  end

  it "uses a custom path" do
    middleware = described_class.new(app, secret:, path: "/hooks/incident") { |_event| nil }

    expect(middleware.call(signed_env(path: "/hooks/incident")).first).to eq(204)
  end

  it "replies 400 to a webhook that fails the check" do
    env = signed_env.merge("HTTP_WEBHOOK_SIGNATURE" => "v1,bm9wZQ==")
    middleware = described_class.new(app, secret:) { raise "should not be called" }

    status, headers, response = middleware.call(env)

    expect(status).to eq(400)
    expect(headers).to eq("content-type" => "text/plain")
    expect(response.first).to start_with("Invalid webhook: no signature matches")
    expect(app_calls).to be_empty
  end

  it "replies 400 to a correctly signed body that isn't JSON" do
    middleware = described_class.new(app, secret:) { raise "should not be called" }

    expect(middleware.call(signed_env(body: "not json")).first).to eq(400)
  end

  it "replies 400 when there is no body" do
    expect(described_class.new(app, secret:).call(signed_env.merge("rack.input" => nil)).first).to eq(400)
  end

  it "lets errors from the block propagate so incident.io retries" do
    middleware = described_class.new(app, secret:) { |_event| raise "database down" }

    expect { middleware.call(signed_env) }.to raise_error(RuntimeError, "database down")
  end

  it "leaves the body readable for the app" do
    env = signed_env
    described_class.new(app, secret:).call(env)

    expect(env["rack.input"].read).to eq(body)
  end

  it "reads bodies that can't be rewound" do
    input = Object.new
    input.define_singleton_method(:read) { JSON.generate("event_type" => "schedule.deleted_v1") }
    env = signed_env(body: input.read, input:)

    expect(described_class.new(app, secret:) { |_event| nil }.call(env).first).to eq(204)
  end
end
