# frozen_string_literal: true

require_relative "generator_helper"

RSpec.describe IncidentIoGenerator::Api, :generator do
  subject(:api) { described_class.new(mini_spec) }

  let(:resource) { api.resources.first }
  let(:ops) { resource.operations.to_h { |op| [op.method_name, op] } }

  it "builds one resource per tag" do
    expect(resource).to have_attributes(tag: "Widgets V2", version: "V2", name: "widgets", class_name: "Widgets",
                                        description: "Manage widgets.")
    expect(ops.keys).to eq(%w[create destroy export list show])
  end

  it "detects paginated lists" do
    expect(ops["list"].result).to have_attributes(kind: :paginated, items_key: "widgets", model: "Models::WidgetV2")
    expect(ops["list"].keyword_params.map(&:name)).to eq(%w[kind page_size after])
  end

  it "unwraps single-key responses" do
    expect(ops["show"].result).to have_attributes(kind: :json, unwrap: "widget", model: "Models::WidgetV2")
    expect(ops["show"].path_params.map(&:name)).to eq(["id"])
  end

  it "handles bodies and idempotency keys" do
    create = ops["create"]

    expect(create.idempotent).to be(true)
    expect(create.keyword_params.map { |p| [p.name, p.required, p.default] })
      .to eq([["name", true, nil], ["idempotency_key", false, "SecureRandom.uuid"], ["part", false, nil]])
  end

  it "handles empty and non-JSON responses" do
    expect(ops["destroy"].result.kind).to eq(:none)
    expect(ops["export"].result).to have_attributes(kind: :text, yard: "String")
  end

  it "marks deprecated operations" do
    expect(ops["destroy"]).to have_attributes(deprecated: true, full_name: "client.v2.widgets.destroy")
  end

  it "points deprecated operations at the newest version" do
    spec = mini_spec
    spec["paths"]["/v3/widgets/{id}"] = { "delete" => operation("Widgets V3#Destroy", nil, code: "204", parameters: [path_param("id")]) }
    destroy = described_class.new(spec).resources.find { |r| r.version == "V2" }.operations.find { |o| o.method_name == "destroy" }

    expect(destroy.replacement).to eq("client.widgets.destroy")
  end

  it "builds models, renaming fields that clash with Ruby methods" do
    widget = api.models.find { |m| m.name == "WidgetV2" }

    expect(widget.file_name).to eq("widget_v2")
    expect(widget.fields.map { |f| [f.api_name, f.member, f.type] }).to eq([
      %w[id id :string],
      %w[class class_ :string],
      %w[created_at created_at :time],
      ["parts", "parts", "[-> { PartV2 }]"],
      ["labels", "labels", "Model.map_of(:string)"],
      %w[kind kind :string]
    ])
    expect(widget.fields.last.description).to eq("One of: big, small.")
  end

  it "applies method overrides" do
    api = described_class.new(mini_spec, "operations" => { "Widgets V2#Export" => { "method" => "export_csv" } })

    expect(api.resources.first.operations.map(&:method_name)).to include("export_csv")
  end

  it "rejects overrides for unknown operations" do
    expect { described_class.new(mini_spec, "operations" => { "Nope V1#List" => { "method" => "x" } }) }
      .to raise_error(IncidentIoGenerator::Error, /unknown operations: Nope V1#List/)
  end

  it "rejects two operations with the same method name" do
    spec = mini_spec
    spec["paths"]["/v2/widgets"]["put"] = operation("Widgets V2#List#1", "WidgetsShowResultV2")

    expect { described_class.new(spec) }.to raise_error(IncidentIoGenerator::Error, /methods share a name, add an override: list/)
  end

  it "rejects parameter names that aren't safe Ruby" do
    spec = mini_spec
    spec["paths"]["/v2/widgets/{id}"]["get"]["parameters"] << { "in" => "query", "name" => "end", "schema" => {} }

    expect { described_class.new(spec) }.to raise_error(IncidentIoGenerator::Error, /"end" is not a safe Ruby name/)
  end

  it "picks the newest version of each resource" do
    spec = mini_spec
    spec["paths"]["/v3/widgets/{id}"] = { "delete" => operation("Widgets V3#Destroy", nil, code: "204", parameters: [path_param("id")]) }

    expect(described_class.new(spec).latest_resources.transform_values(&:version)).to eq("widgets" => "V3")
  end
end
