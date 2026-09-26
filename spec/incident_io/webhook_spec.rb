# frozen_string_literal: true

RSpec.describe IncidentIo::Webhook do
  # Svix's published test vector, also used in incident.io's webhook docs.
  let(:secret) { "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw" }
  let(:payload) { '{"test": 2432232314}' }
  let(:sent_at) { 1_614_265_330 }
  let(:now) { Time.at(sent_at) }
  let(:headers) do
    {
      "webhook-id" => "msg_p5jXN8AQM9LWM0D4loKWxJek",
      "webhook-timestamp" => sent_at.to_s,
      "webhook-signature" => "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
    }
  end

  describe ".sign" do
    it "matches the Svix test vector" do
      signature = described_class.sign(payload, id: headers["webhook-id"], timestamp: sent_at, secret:)

      expect(signature).to eq("g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
    end
  end

  describe ".verify!" do
    def verify(payload: self.payload, headers: self.headers, secret: self.secret, now: self.now)
      described_class.verify!(payload, headers, secret:, now:)
    end

    it "accepts a correctly signed webhook" do
      expect(verify).to be(true)
    end

    it "accepts the secret without its whsec_ prefix" do
      expect(verify(secret: secret.delete_prefix("whsec_"))).to be(true)
    end

    it "accepts any matching signature among several" do
      signatures = "v1,bm90IGl0 #{headers["webhook-signature"]}"

      expect(verify(headers: headers.merge("webhook-signature" => signatures))).to be(true)
    end

    it "accepts header names in any case, Svix's old names and Rack env keys" do
      rack_env = headers.to_h { |k, v| ["HTTP_#{k.upcase.tr("-", "_")}", v] }.merge("rack.input" => StringIO.new)
      svix = headers.transform_keys { |k| k.sub("webhook-", "svix-") }
      title_case = headers.transform_keys { |k| k.split("-").map(&:capitalize).join("-") }

      expect([rack_env, svix, title_case].map { |h| verify(headers: h) }).to all(be(true))
    end

    it "rejects a changed payload" do
      expect { verify(payload: '{"test": 1}') }.to raise_error(described_class::SignatureError, "no signature matches")
    end

    it "rejects the wrong secret" do
      expect { verify(secret: "whsec_c2VjcmV0") }.to raise_error(described_class::SignatureError)
    end

    it "ignores signatures with other versions" do
      signature = headers["webhook-signature"].sub("v1,", "v2,")

      expect { verify(headers: headers.merge("webhook-signature" => signature)) }
        .to raise_error(described_class::SignatureError)
    end

    it "rejects webhooks sent too long ago or too far ahead" do
      expect { verify(now: now + 301) }.to raise_error(described_class::SignatureError, /outside the tolerance/)
      expect { verify(now: now - 301) }.to raise_error(described_class::SignatureError, /outside the tolerance/)
      expect(verify(now: now + 300)).to be(true)
    end

    it "rejects missing headers" do
      expect { verify(headers: headers.except("webhook-signature")) }
        .to raise_error(described_class::SignatureError, /missing/)
    end

    it "rejects a timestamp that isn't a number" do
      expect { verify(headers: headers.merge("webhook-timestamp" => "soon")) }
        .to raise_error(described_class::SignatureError, "invalid webhook-timestamp header")
    end

    it "raises a configuration error for a malformed secret" do
      expect { verify(secret: "whsec_not base64!") }.to raise_error(IncidentIo::ConfigurationError)
    end
  end

  describe ".parse" do
    it "builds the payload model for known events" do
      event = described_class.parse(JSON.generate(
        "event_type" => "public_incident.incident_created_v2",
        "public_incident.incident_created_v2" => {"id" => "01ABC", "name" => "DB down"}
      ))

      expect(event.type).to eq("public_incident.incident_created_v2")
      expect(event.data).to be_a(IncidentIo::Models::WebhookIncidentV2)
      expect(event.data.name).to eq("DB down")
      expect(event.raw["event_type"]).to eq("public_incident.incident_created_v2")
      expect(event.id).to be_nil
    end

    it "builds the ID-only model for private events" do
      event = described_class.parse({
        "event_type" => "private_incident.incident_created_v2",
        "private_incident.incident_created_v2" => {"id" => "01ABC"}
      })

      expect(event.data).to eq(IncidentIo::Models::WebhookPrivateResourceV2.new(id: "01ABC"))
    end

    it "keeps the raw payload for event types it doesn't know" do
      event = described_class.parse({"event_type" => "new_thing.created_v1", "new_thing.created_v1" => {"id" => "1"}})

      expect(event.data).to eq("id" => "1")
    end

    it "knows every event type in the spec" do
      expect(described_class::EVENTS.size).to eq(34)
      expect(described_class::EVENTS.values.uniq).to all(satisfy { |m| IncidentIo::Models.const_get(m) })
    end
  end

  describe ".construct_event" do
    it "checks the signature, then parses the webhook with its ID" do
      body = JSON.generate("event_type" => "schedule.deleted_v1", "schedule.deleted_v1" => {"id" => "01S"})
      sent_at = Time.now.to_i
      signature = described_class.sign(body, id: "msg_1", timestamp: sent_at, secret:)
      headers = {"webhook-id" => "msg_1", "webhook-timestamp" => sent_at.to_s, "webhook-signature" => "v1,#{signature}"}

      event = described_class.construct_event(body, headers, secret:)

      expect(event).to have_attributes(id: "msg_1", type: "schedule.deleted_v1")
      expect(event.data).to be_a(IncidentIo::Models::ScheduleSlimV2)
    end

    it "does not parse a webhook that fails the check" do
      expect(described_class).not_to receive(:parse)

      expect { described_class.construct_event(payload, headers, secret:) }
        .to raise_error(described_class::SignatureError)
    end
  end
end
