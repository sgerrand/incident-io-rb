# frozen_string_literal: true

require "tmpdir"
require_relative "generator_helper"

RSpec.describe IncidentIoGenerator::BreakingChanges, :generator do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  # Generates code from a spec into its own root and returns the root.
  def generate(name, spec)
    File.join(@dir, name).tap { |root| IncidentIoGenerator::Writer.new(IncidentIoGenerator::Api.new(spec), root).write }
  end

  # The mini spec before a breaking update. It has an extra event, entry,
  # model, field and method, a field of another type, and methods with
  # other arguments, argument types and return types.
  def older_spec
    mini_spec.tap do |spec|
      schemas = spec["components"]["schemas"]
      schemas["GadgetV1"] = {"type" => "object", "properties" => {"id" => {"type" => "string"}}}
      schemas["WidgetDeletedBody"] = {
        "type" => "object",
        "properties" => {"public_widget.deleted_v1" => {"$ref" => "#/components/schemas/WidgetV2"}}
      }
      schemas["WidgetV2"]["properties"]["colour"] = {"type" => "string"}
      schemas["PartV2"]["properties"]["id"] = {"type" => "integer"}
      schemas["WidgetsCreatePayloadV2"]["required"] = ["idempotency_key"]
      schemas["WidgetsCreatePayloadV2"]["properties"]["colour"] = {"type" => "string"}

      spec["x-webhooks"]["/x-webhooks/public_widget.deleted_v1"] = event("WidgetDeletedBody", "Widget deleted.")
      spec["x-webhooks"]["/x-audit-logs/widget.created.1"] = event("AuditLogsWidgetDeletedV2", "Widget created.")

      paths = spec["paths"]
      paths["/v2/widgets/{id}/archive"] = {
        "post" => operation("Widgets V2#Archive", "WidgetsShowResultV2", parameters: [path_param("id")])
      }
      paths["/v2/shelves/{shelf_id}/widgets/{id}/export"] = {
        "get" => operation("Widgets V2#Export", nil, parameters: [path_param("shelf_id"), path_param("id")],
          content_type: "text/csv")
      }
      paths.delete("/v2/widgets/{id}/export")
      paths["/v2/widgets"]["get"]["parameters"][0]["schema"] = {"type" => "string"}
      paths["/v2/widgets/{id}"]["delete"] = operation("Widgets V2#Destroy", "WidgetsShowResultV2", parameters: [path_param("id")])
    end
  end

  it "lists what the newer code removed or changed" do
    report = described_class.report(generate("before", older_spec), generate("after", mini_spec))

    expect(report).to eq(<<~MARKDOWN)
      ## Breaking changes

      The latest spec removes or changes these. Each one can break code that uses the gem.

      - Webhook event `public_widget.deleted_v1` was removed
      - Audit log entry `widget.created` (version 1) was removed
      - Model `GadgetV1` was removed
      - Model `WidgetDeletedBody` was removed
      - Field `PartV2#id` changed type from `Integer` to `String`
      - Field `WidgetV2#colour` was removed
      - Field `WidgetsCreatePayloadV2#colour` was removed
      - Method `client.v2.widgets.archive` was removed
      - Method `client.v2.widgets.create` no longer takes `colour:`
      - Method `client.v2.widgets.create` now needs `name:`
      - Method `client.v2.widgets.destroy` changed what it returns from `Models::WidgetV2` to `nil`
      - Method `client.v2.widgets.export` changed its positional arguments from `(shelf_id, id)` to `(id)`
      - Method `client.v2.widgets.list` changed the type of argument `page_size` from `String` to `Integer`
    MARKDOWN
  end

  it "is empty when things were only added or made optional" do
    expect(described_class.report(generate("before", mini_spec), generate("after", mini_spec.tap do |spec|
      schemas = spec["components"]["schemas"]
      schemas["GadgetV1"] = {"type" => "object"}
      schemas["WidgetV2"]["properties"]["colour"] = {"type" => "string"}
      schemas["WidgetsCreatePayloadV2"]["required"] = ["idempotency_key"]
      schemas["WidgetsCreatePayloadV2"]["properties"]["colour"] = {"type" => "string"}
    end))).to eq("")
  end

  it "stops at the limit and counts the rest" do
    stub_const("#{described_class}::LIMIT", 2)

    report = described_class.report(generate("before", older_spec), generate("after", mini_spec))

    expect(report.lines.last(3)).to eq([
      "- Webhook event `public_widget.deleted_v1` was removed\n",
      "- Audit log entry `widget.created` (version 1) was removed\n",
      "- and 11 more\n"
    ])
  end

  describe "the real generated code" do
    let(:surface) { described_class.surface(IncidentIoGenerator::ROOT) }

    it "has every event and entry type read" do
      expect(surface[:events]).to match_array(IncidentIo::Webhook::EVENTS.keys)
      expect(surface[:entries].size).to eq(IncidentIo::AuditLog::ENTRIES.size)
    end

    it "has every model and field read" do
      models = IncidentIo::Models.constants.to_h { |name| [name.to_s, IncidentIo::Models.const_get(name).members.map(&:to_s)] }

      expect(surface[:models].transform_values(&:keys)).to eq(models)
      expect(surface[:models].values.flat_map(&:values)).to all(match(/\A[A-Z]/))
    end

    # rbs test wraps every method, which hides the arguments it takes.
    it "has every method read with the arguments it really takes", skip: ENV.key?("RBS_TEST_TARGET") && "not under rbs test" do
      client = IncidentIo::Client.new(api_key: "k")
      real = surface[:methods].keys.to_h do |call|
        *resource, method = call.split(".").drop(1)
        by_kind = resource.inject(client, :public_send).method(method).parameters.group_by(&:first)
        names = ->(kind) { by_kind.fetch(kind, []).map { |_, name| name.to_s } }
        [call, {positional: names[:req], required: names[:keyreq], optional: names[:key] - ["request_options"]}]
      end

      expect(surface[:methods].size).to eq(JSON.parse(File.read(File.join(IncidentIoGenerator::ROOT, described_class::OPERATIONS_PATH))).size)
      expect(surface[:methods].transform_values { |m| m.slice(:positional, :required, :optional) }).to eq(real)
      expect(surface[:methods].values.flat_map { |m| [m[:returns], *m[:types].values] }).to all(match(/\A[A-Za-z]/))
    end
  end
end
