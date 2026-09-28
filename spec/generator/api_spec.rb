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

  it "writes the model source for nested array results" do
    result = IncidentIoGenerator::Result.new(kind: :json, yard: "Array", rbs: "Array", model_name: "WidgetV2", depth: 2)

    expect(result.model).to eq("[[Models::WidgetV2]]")
  end

  it "handles bodies and idempotency keys" do
    create = ops["create"]

    expect(create.idempotent).to be(true)
    expect(create.keyword_params.map { |p| [p.name, p.location, p.required, p.default, p.not_given?] })
      .to eq([
        ["name", :body, true, nil, false],
        ["idempotency_key", :body, false, "SecureRandom.uuid", false],
        ["part", :body, false, nil, true]
      ])
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
    spec["paths"]["/v3/widgets/{id}"] = {"delete" => operation("Widgets V3#Destroy", nil, code: "204", parameters: [path_param("id")])}
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

  it "reads webhook events and audit log entries" do
    expect(api.webhook_events).to eq([
      IncidentIoGenerator::WebhookEvent.new(type: "public_widget.created_v1", description: "Widget created.",
        model: "WidgetV2")
    ])
    expect(api.audit_log_entries).to eq([
      IncidentIoGenerator::AuditLogEntry.new(action: "widget.deleted", version: 2, description: "Widget deleted.",
        model: "AuditLogsWidgetDeletedV2")
    ])
  end

  it "rejects x-webhooks entries it doesn't understand" do
    spec = mini_spec
    spec["x-webhooks"]["/x-other/thing"] = event("WidgetCreatedBody", "?")

    expect { described_class.new(spec) }.to raise_error(IncidentIoGenerator::Error, %r{unknown x-webhooks entry: /x-other/thing})
  end

  it "applies method overrides" do
    api = described_class.new(mini_spec, "operations" => {"Widgets V2#Export" => {"method" => "export_csv"}})

    expect(api.resources.first.operations.map(&:method_name)).to include("export_csv")
  end

  it "rejects overrides for unknown operations" do
    expect { described_class.new(mini_spec, "operations" => {"Nope V1#List" => {"method" => "x"}}) }
      .to raise_error(IncidentIoGenerator::Error, /unknown operations: Nope V1#List/)
  end

  it "rejects two operations with the same method name" do
    spec = mini_spec
    spec["paths"]["/v2/widgets"]["put"] = operation("Widgets V2#List#1", "WidgetsShowResultV2")

    expect { described_class.new(spec) }.to raise_error(IncidentIoGenerator::Error, /methods share a name, add an override: list/)
  end

  it "rejects parameter names that aren't safe Ruby" do
    spec = mini_spec
    spec["paths"]["/v2/widgets/{id}"]["get"]["parameters"] << {"in" => "query", "name" => "end", "schema" => {}}

    expect { described_class.new(spec) }.to raise_error(IncidentIoGenerator::Error, /"end" is not a safe Ruby name/)
  end

  it "picks the newest version of each resource" do
    spec = mini_spec
    spec["paths"]["/v3/widgets/{id}"] = {"delete" => operation("Widgets V3#Destroy", nil, code: "204", parameters: [path_param("id")])}

    expect(described_class.new(spec).latest_resources.transform_values(&:version)).to eq("widgets" => "V3")
  end

  describe "validation" do
    {
      "two schemas with the same file name" => [/models share a file name: widget_v2/, ->(s) {
        s["components"]["schemas"]["Widget_V2"] = {"type" => "object"}
      }],
      "a webhook without a response schema" => [/no response schema/, ->(s) {
        s["x-webhooks"]["/x-webhooks/public_widget.created_v1"]["get"]["responses"] = {"200" => {}}
      }],
      "a webhook body without its payload" => [/body has no public_widget.created_v1 payload/, ->(s) {
        s["components"]["schemas"]["WidgetCreatedBody"]["properties"].delete("public_widget.created_v1")
      }],
      "a resource named like a Client method" => [/resource name request clashes with a Client method/, ->(s) {
        s["paths"]["/v1/request"] = {"get" => operation("Request V1#Show", "WidgetsShowResultV2")}
      }],
      "a resource named like a private Client method" => [/resource name log clashes with a Client method/, ->(s) {
        s["paths"]["/v2/log"] = {"get" => operation("Log V2#Show", "WidgetsShowResultV2")}
      }],
      "a paginated GET with a body" => [/Widgets V2#List: paginated operations must be GETs without a body/, ->(s) {
        s["paths"]["/v2/widgets"]["get"]["requestBody"] = s["paths"]["/v2/widgets"]["post"]["requestBody"]
      }],
      "a paginated POST" => [/Searches V2#List: paginated operations must be GETs without a body/, ->(s) {
        after = {"in" => "query", "name" => "after", "schema" => {"type" => "string"}}
        s["paths"]["/v2/searches"] = {"post" => operation("Searches V2#List", "WidgetsListResultV2", parameters: [after])}
      }],
      "a resource named like a version accessor" => [/resource name v2 clashes with a version accessor/, ->(s) {
        s["paths"]["/v1/v2"] = {"get" => operation("V2 V1#Show", "WidgetsShowResultV2")}
      }],
      "a tag without a version" => [/tag has no version: "Things"/, ->(s) {
        s["paths"]["/v1/things"] = {"get" => operation("Things#Show", "WidgetsShowResultV2")}
      }],
      "an operation without a 2xx response" => [/Widgets V2#List: no 2xx response/, ->(s) {
        s["paths"]["/v2/widgets"]["get"]["responses"] = {"400" => {"description" => "Bad"}}
      }],
      "a paginated response without exactly one array" => [/needs exactly one array/, ->(s) {
        s["components"]["schemas"]["WidgetsListResultV2"]["properties"]["others"] = {"type" => "array"}
      }],
      "a reserved parameter name" => [/"request_options" is reserved/, ->(s) {
        s["paths"]["/v2/widgets/{id}"]["get"]["parameters"] << {"in" => "query", "name" => "request_options", "schema" => {}}
      }],
      "a parameter used twice" => [/parameter names used twice: name/, ->(s) {
        s["paths"]["/v2/widgets"]["post"]["parameters"] = [{"in" => "query", "name" => "name", "schema" => {}}]
      }]
    }.each do |problem, (message, change)|
      it "rejects #{problem}" do
        spec = mini_spec
        instance_exec(spec, &change)

        expect { described_class.new(spec) }.to raise_error(IncidentIoGenerator::Error, message)
      end
    end

    it "reserves every method Client defines" do
      client_methods = IncidentIo::Client.instance_methods(false) + IncidentIo::Client.private_instance_methods(false) +
        IncidentIo::Resources::Accessors.private_instance_methods(false)

      # `rake spec:rbs` wraps each checked method in extra "__RBS_TEST_" ones.
      names = client_methods.map(&:to_s).grep_v(/__RBS_TEST_/)

      expect(described_class::CLIENT_METHODS).to include(*names)
    end

    it "rejects a method named like a Resource helper" do
      expect { described_class.new(mini_spec, "operations" => {"Widgets V2#Show" => {"method" => "request"}}) }
        .to raise_error(IncidentIoGenerator::Error, /clashes with a Resource helper/)
    end
  end

  it "ignores path item keys that aren't HTTP methods" do
    spec = mini_spec
    spec["paths"]["/v2/widgets"]["parameters"] = []

    expect(described_class.new(spec).resources.first.operations.size).to eq(5)
  end

  it "points deprecated operations at the newest resource when it lacks the method" do
    spec = mini_spec
    spec["paths"]["/v3/widgets"] = {"get" => operation("Widgets V3#Search", "WidgetsShowResultV2")}
    destroy = described_class.new(spec).resources.first.operations.find { |o| o.method_name == "destroy" }

    expect(destroy.replacement).to eq("client.widgets")
  end

  it "reads inline request bodies and returns whole results with several fields" do
    spec = mini_spec
    spec["components"]["schemas"]["WidgetsPairResultV2"] = {
      "type" => "object", "properties" => {"a" => {"type" => "string"}, "b" => {"type" => "string"}}
    }
    op = operation("Widgets V2#Pair", "WidgetsPairResultV2")
    op["requestBody"] = {"content" => {"application/json" => {"schema" => {
      "type" => "object", "properties" => {"note" => {"type" => "string"}}
    }}}}
    spec["paths"]["/v2/widgets/pair"] = {"post" => op}
    pair = described_class.new(spec).resources.first.operations.find { |o| o.method_name == "pair" }

    expect(pair.body_params.map(&:name)).to eq(["note"])
    expect(pair.result).to have_attributes(kind: :json, unwrap: nil, model: "Models::WidgetsPairResultV2")
  end
end
