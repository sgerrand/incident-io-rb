# frozen_string_literal: true

RSpec.describe IncidentIo::Resource do
  let(:client) { IncidentIo::Client.new(api_key: "k") }
  let(:model) { IncidentIo::Model.define(id: :string, name: :string) }
  let(:resource_class) do
    m = model
    Class.new(described_class) do
      define_method(:show) do |id, **request_options|
        request(:get, path("/v2/incidents/%s", id), unwrap: "incident", model: m, request_options:)
      end

      define_method(:list) do |**query|
        paginate("/v2/incidents", items_key: "incidents", query:, model: m)
      end
    end
  end
  let(:resource) { resource_class.new(client) }

  it "unwraps the response and builds the model" do
    stub_request(:get, "#{BASE_URL}/v2/incidents/01ABC")
      .to_return(json_response({"incident" => {"id" => "01ABC", "name" => "DB down"}}))

    expect(resource.show("01ABC")).to eq(model.new(id: "01ABC", name: "DB down"))
  end

  it "escapes IDs in the path" do
    stub = stub_request(:get, "#{BASE_URL}/v2/incidents/a%2F..%2Fb").to_return(json_response({"incident" => {}}))

    resource.show("a/../b")

    expect(stub).to have_been_requested
  end

  it "paginates" do
    stub_request(:get, "#{BASE_URL}/v2/incidents")
      .to_return(json_response({"incidents" => [{"id" => "1"}], "pagination_meta" => {}}))

    expect(resource.list.map(&:id)).to eq(["1"])
  end
end
