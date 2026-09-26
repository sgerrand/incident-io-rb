# frozen_string_literal: true

RSpec.describe IncidentIo::AuditLog do
  let(:entry) do
    {
      "action" => "alert_route.created",
      "version" => 1,
      "occurred_at" => "2021-08-17T13:28:57.801578Z",
      "actor" => {"id" => "01U", "name" => "John Doe", "type" => "user"},
      "targets" => [{"id" => "01R", "name" => "Production incidents", "type" => "alert_route"}],
      "context" => {"location" => "1.2.3.4", "user_agent" => "Chrome/91.0.4472.114"}
    }
  end

  it "builds the model for the entry's action and version" do
    parsed = described_class.parse(JSON.generate(entry))

    expect(parsed).to be_a(IncidentIo::Models::AuditLogsAlertRouteCreatedV1)
    expect(parsed.actor.name).to eq("John Doe")
    expect(parsed.occurred_at).to eq(Time.utc(2021, 8, 17, 13, 28, 57.801578r))
  end

  it "keeps the raw entry for types it doesn't know" do
    expect(described_class.parse(entry.merge("version" => 99))).to eq(entry.merge("version" => 99))
  end

  it "knows every entry type in the spec" do
    expect(described_class::ENTRIES.size).to eq(219)
  end
end
