# frozen_string_literal: true

require "tmpdir"
require_relative "generator_helper"

RSpec.describe IncidentIoGenerator::Removals, :generator do
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

  # The mini spec with an extra event, entry, model, field and method.
  def bigger_spec
    mini_spec.tap do |spec|
      schemas = spec["components"]["schemas"]
      schemas["GadgetV1"] = {"type" => "object", "properties" => {"id" => {"type" => "string"}}}
      schemas["WidgetDeletedBody"] = {
        "type" => "object",
        "properties" => {"public_widget.deleted_v1" => {"$ref" => "#/components/schemas/WidgetV2"}}
      }
      schemas["WidgetV2"]["properties"]["colour"] = {"type" => "string"}
      spec["x-webhooks"]["/x-webhooks/public_widget.deleted_v1"] = event("WidgetDeletedBody", "Widget deleted.")
      spec["x-webhooks"]["/x-audit-logs/widget.created.1"] = event("AuditLogsWidgetDeletedV2", "Widget created.")
      spec["paths"]["/v2/widgets/{id}/archive"] = {
        "post" => operation("Widgets V2#Archive", "WidgetsShowResultV2", parameters: [path_param("id")])
      }
    end
  end

  it "lists what the newer code no longer has" do
    report = described_class.report(generate("before", bigger_spec), generate("after", mini_spec))

    expect(report).to eq(<<~MARKDOWN)
      ## Removed

      The latest spec no longer has these. Removing them can break code that uses the gem.

      - Webhook event `public_widget.deleted_v1`
      - Audit log entry `widget.created` (version 1)
      - Model `GadgetV1`
      - Model `WidgetDeletedBody`
      - Field `WidgetV2#colour`
      - Method `client.v2.widgets.archive`
    MARKDOWN
  end

  it "is empty when things were only added" do
    expect(described_class.report(generate("before", mini_spec), generate("after", bigger_spec))).to eq("")
  end

  it "stops at the limit and counts the rest" do
    stub_const("#{described_class}::LIMIT", 2)

    report = described_class.report(generate("before", bigger_spec), generate("after", mini_spec))

    expect(report.lines.last(3)).to eq([
      "- Webhook event `public_widget.deleted_v1`\n",
      "- Audit log entry `widget.created` (version 1)\n",
      "- and 4 more\n"
    ])
  end

  it "reads everything in the real generated code" do
    surface = described_class.surface(IncidentIoGenerator::ROOT)
    manifest = JSON.parse(File.read(File.join(IncidentIoGenerator::ROOT, described_class::OPERATIONS_PATH)))
    models = IncidentIo::Models.constants.to_h { |name| [name.to_s, IncidentIo::Models.const_get(name).members.map(&:to_s)] }

    expect(surface[:events]).to match_array(IncidentIo::Webhook::EVENTS.keys)
    expect(surface[:entries].size).to eq(IncidentIo::AuditLog::ENTRIES.size)
    expect(surface[:models]).to eq(models)
    expect(surface[:methods].uniq.size).to eq(manifest.size)
  end
end
