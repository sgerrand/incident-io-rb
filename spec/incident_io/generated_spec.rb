# frozen_string_literal: true

# Checks the generated code in lib/incident_io against the real spec.
RSpec.describe "generated resources" do
  let(:client) { IncidentIo::Client.new(api_key: "k") }

  it "loads every model and resource" do
    models = IncidentIo::Models.constants.map { |c| IncidentIo::Models.const_get(c) }
    resources = %i[V1 V2 V3].flat_map do |v|
      mod = IncidentIo::Resources.const_get(v)
      mod.constants.map { |c| mod.const_get(c) }
    end

    expect(models.size).to be > 1000
    expect(resources).to all(be_a(Class))
  end

  it "gives the newest version of each resource by default" do
    expect(client.incidents).to be_a(IncidentIo::Resources::V2::Incidents)
    expect(client.actions).to be_a(IncidentIo::Resources::V3::Actions)
    expect(client.catalog).to be_a(IncidentIo::Resources::V3::Catalog)
    expect(client.v1.incidents).to be_a(IncidentIo::Resources::V1::Incidents)
    expect(client.incidents).to be(client.incidents)
  end

  it "shows an incident" do
    stub_request(:get, "#{BASE_URL}/v2/incidents/01ABC").to_return(
      json_response({"incident" => {"id" => "01ABC", "name" => "DB down", "created_at" => "2024-05-01T12:00:00Z",
                                    "severity" => {"id" => "s1", "name" => "Major"}}})
    )

    incident = client.incidents.show("01ABC")

    expect(incident).to be_a(IncidentIo::Models::IncidentV2)
    expect(incident.created_at).to eq(Time.utc(2024, 5, 1, 12))
    expect(incident.severity.name).to eq("Major")
  end

  it "creates an incident with an idempotency key and retries safely" do
    bodies = []
    stub_request(:post, "#{BASE_URL}/v2/incidents")
      .with { |req| bodies << JSON.parse(req.body) }
      .to_return(json_response(error_body(status: 500, type: "internal_error"), status: 500),
        json_response({"incident" => {"id" => "1"}}, status: 201))
    allow(client).to receive(:sleep)

    incident = client.incidents.create(visibility: "public", name: "DB down")

    expect(incident.id).to eq("1")
    expect(bodies.size).to eq(2)
    expect(bodies.first).to include("visibility" => "public", "name" => "DB down")
    expect(bodies.first["idempotency_key"]).to match(/\A\h{8}-/)
    expect(bodies.map { |b| b["idempotency_key"] }.uniq.size).to eq(1)
    expect(bodies.first).not_to have_key("summary")
  end

  it "sends nil as null and leaves out arguments that weren't passed" do
    stub = stub_request(:post, "#{BASE_URL}/v2/incidents")
      .with { |req| JSON.parse(req.body).then { |b| b.key?("summary") && b["summary"].nil? && !b.key?("name") } }
      .to_return(json_response({"incident" => {"id" => "1"}}, status: 201))

    client.incidents.create(visibility: "public", summary: nil)

    expect(stub).to have_been_requested
  end

  it "sends nil fields set on a nested model as null" do
    stub = stub_request(:post, "#{BASE_URL}/v2/incidents/1/actions/edit").with(
      body: {"incident" => {"name" => "New name", "summary" => nil}, "notify_incident_channel" => false}
    ).to_return(json_response({"incident" => {"id" => "1"}}))

    client.incidents.edit("1", incident: IncidentIo::Models::IncidentEditPayloadV2.new(name: "New name", summary: nil),
      notify_incident_channel: false)

    expect(stub).to have_been_requested
  end

  it "accepts models and hashes as arguments" do
    stub = stub_request(:post, "#{BASE_URL}/v2/incidents/1/actions/edit").with(
      body: {"incident" => {"name" => "New name"}, "notify_incident_channel" => false}
    ).to_return(json_response({"incident" => {"id" => "1"}}))

    client.incidents.edit("1", incident: IncidentIo::Models::IncidentEditPayloadV2.new(name: "New name"),
      notify_incident_channel: false)

    expect(stub).to have_been_requested
  end

  it "lists incidents with filters, page by page" do
    stub_request(:get, "#{BASE_URL}/v2/incidents")
      .with(query: {"page_size" => "1", "status_category[one_of]" => "live"})
      .to_return(json_response({"incidents" => [{"id" => "1"}], "pagination_meta" => {"after" => "1"}}))
    stub_request(:get, "#{BASE_URL}/v2/incidents")
      .with(query: {"page_size" => "1", "status_category[one_of]" => "live", "after" => "1"})
      .to_return(json_response({"incidents" => [{"id" => "2"}], "pagination_meta" => {}}))

    pager = client.incidents.list(page_size: 1, status_category: {one_of: ["live"]})

    expect(pager).to be_a(IncidentIo::Pager)
    expect(pager.map(&:id)).to eq(%w[1 2])
  end

  it "returns nil for deletes" do
    stub_request(:delete, "#{BASE_URL}/v2/schedules/1").to_return(status: 204)

    expect(client.schedules.destroy("1")).to be_nil
  end

  it "returns CSV downloads as text" do
    stub_request(:get, "#{BASE_URL}/v2/pay_reports/1/download")
      .to_return(status: 200, body: "a,b\n", headers: {"Content-Type" => "text/csv"})

    expect(client.pay_reports.download("1")).to eq("a,b\n")
  end

  it "requires required arguments" do
    # Under `rake spec:rbs` the signature check rejects the call before Ruby does.
    if ENV["RBS_TEST_TARGET"]
      expect { client.incidents.create(name: "x") }.to raise_error(RBS::Test::Tester::TypeError, /visibility:/)
    else
      expect { client.incidents.create(name: "x") }.to raise_error(ArgumentError, /missing keyword: :visibility/)
    end
  end

  describe "deprecated endpoints" do
    around do |example|
      before = Warning[:deprecated]
      Warning[:deprecated] = true
      example.run
    ensure
      Warning[:deprecated] = before
    end

    it "warns once, pointing at the newer method" do
      stub_request(:get, "#{BASE_URL}/v2/catalog_types/1").to_return(json_response({"catalog_type" => {"id" => "1"}}))
      allow(IncidentIo::Resource).to receive(:first_deprecation_warning?).and_return(true, false)

      expect { client.v2.catalog.show_type("1") }
        .to output(/client\.v2\.catalog\.show_type is deprecated by incident\.io; use client\.catalog\.show_type instead/).to_stderr
      expect { client.v2.catalog.show_type("1") }.not_to output.to_stderr
    end
  end
end
