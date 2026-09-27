# frozen_string_literal: true

RSpec.describe IncidentIo::Model do
  let(:severity) { described_class.define(id: :string, name: :string, rank: :integer) }
  let(:incident) do
    sev = severity
    described_class.define(
      id: :string,
      created_at: :time,
      due_on: :date,
      score: :float,
      severity: -> { sev },
      tags: [:string],
      history: [-> { sev }],
      lookup: described_class.map_of(-> { sev }),
      class: :string,
      method: :string
    )
  end

  let(:payload) do
    {
      "id" => "01ABC",
      "created_at" => "2024-05-01T12:00:00Z",
      "due_on" => "2024-05-02",
      "score" => 1,
      "severity" => {"id" => "s1", "name" => "Major", "rank" => 2},
      "tags" => %w[a b],
      "history" => [{"id" => "s0"}],
      "lookup" => {"k" => {"id" => "s2"}},
      "class" => "thing",
      "method" => "email",
      "added_later" => "surprise"
    }
  end

  subject(:model) { incident.from_api(payload) }

  it "coerces field types" do
    expect(model.id).to eq("01ABC")
    expect(model.created_at).to eq(Time.utc(2024, 5, 1, 12))
    expect(model.due_on).to eq(Date.new(2024, 5, 2))
    expect(model.score).to eq(1.0)
    expect(model.severity).to eq(severity.new(id: "s1", name: "Major", rank: 2))
    expect(model.tags).to eq(%w[a b])
    expect(model.history.first.id).to eq("s0")
    expect(model.lookup["k"].id).to eq("s2")
  end

  it "renames fields that clash with Ruby methods" do
    expect(model.class_).to eq("thing")
    expect(model.method_).to eq("email")
    expect(model.class).to eq(incident)
  end

  it "turns field names that aren't valid Ruby into method names" do
    klass = described_class.define("private_alert.alert_created_v1": :string)

    expect(klass.from_api("private_alert.alert_created_v1" => "x").private_alert_alert_created_v1).to eq("x")
    expect(klass.new(private_alert_alert_created_v1: "x").to_api).to eq("private_alert.alert_created_v1" => "x")
  end

  it "keeps unknown fields readable" do
    expect(model[:added_later]).to eq("surprise")
    expect(model.raw).to eq(payload)
  end

  it "fills missing fields with nil" do
    expect(incident.from_api({"id" => "x"})).to have_attributes(id: "x", severity: nil, tags: nil)
  end

  it "is frozen and compares by value" do
    expect(model).to be_frozen
    expect(incident.from_api(payload)).to eq(model)
  end

  it "serializes back to API field names" do
    expect(model.to_api).to include(
      "id" => "01ABC",
      "created_at" => "2024-05-01T12:00:00.000Z",
      "due_on" => "2024-05-02",
      "severity" => {"id" => "s1", "name" => "Major", "rank" => 2},
      "class" => "thing"
    )
  end

  it "can be built by hand and rejects unknown keywords" do
    expect(severity.new(id: "s").name).to be_nil
    expect { severity.new(nope: 1) }.to raise_error(ArgumentError, "unknown keyword: nope")
    expect { severity.new(nope: 1, nah: 2) }.to raise_error(ArgumentError, "unknown keywords: nope, nah")
  end

  it "has no raw payload when built by hand" do
    expect(severity.new(id: "s")[:id]).to be_nil
  end

  it "returns a model it is given unchanged" do
    expect(incident.from_api(model)).to be(model)
  end

  describe "which fields are sent" do
    it "sends fields passed to new, with nil as null, and leaves the rest out" do
      expect(severity.new(id: "s1", name: nil).to_api).to eq("id" => "s1", "name" => nil)
    end

    it "sends only the keys the API gave, keeping nulls" do
      expect(severity.from_api("id" => "s1", "name" => nil).to_api).to eq("id" => "s1", "name" => nil)
    end

    it "keeps given fields and the raw payload through #with" do
      original = severity.from_api("id" => "s1", "extra" => true)
      changed = original.with(name: nil)

      expect(changed.to_api).to eq("id" => "s1", "name" => nil)
      expect(changed[:extra]).to be(true)
      expect(changed).to be_a(severity)
    end

    it "returns itself from #with without changes" do
      model = severity.new(id: "s1")

      expect(model.with).to be(model)
    end
  end

  it "keeps floats as they are" do
    expect(incident.from_api("score" => 2.5).score).to eq(2.5)
  end

  it "keeps a bad date string rather than failing" do
    expect(incident.from_api("due_on" => "not a date").due_on).to eq("not a date")
  end

  it "keeps a bad time string rather than failing" do
    expect(incident.from_api("created_at" => "not a time").created_at).to eq("not a time")
  end

  it "returns nil for nil" do
    expect(incident.from_api(nil)).to be_nil
  end

  it "accepts a block of extra methods" do
    klass = described_class.define(status: :string) do
      def closed? = status == "closed"
    end

    expect(klass.from_api("status" => "closed")).to be_closed
  end
end
