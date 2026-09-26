# frozen_string_literal: true

require "tmpdir"
require_relative "generator_helper"

RSpec.describe IncidentIoGenerator::Writer, :generator do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:api) { IncidentIoGenerator::Api.new(mini_spec) }

  def generated(path)
    File.read(File.join(@dir, path))
  end

  it "writes index, model and resource files" do
    files = described_class.new(api, @dir).write

    models = %w[audit_logs_widget_deleted_v2 part_v2 pagination_meta_result_v2 widget_created_body widget_v2
      widgets_create_payload_v2 widgets_list_result_v2 widgets_show_result_v2]

    expect(files).to contain_exactly(
      "lib/incident_io/models.rb", "lib/incident_io/resources.rb", "sig/incident_io/resources.rbs",
      "lib/incident_io/resources/v2/widgets.rb", "sig/incident_io/resources/v2/widgets.rbs",
      "lib/incident_io/webhook_events.rb", "sig/incident_io/webhook_events.rbs",
      "lib/incident_io/audit_log_entries.rb", "sig/incident_io/audit_log_entries.rbs",
      *models.map { |m| "lib/incident_io/models/#{m}.rb" },
      *models.map { |m| "sig/incident_io/models/#{m}.rbs" }
    )
  end

  it "writes valid Ruby" do
    files = described_class.new(api, @dir).write

    files.grep(/\.rb\z/).each do |path|
      expect { RubyVM::InstructionSequence.compile(generated(path)) }.not_to raise_error, path
    end
  end

  it "removes files left over from an earlier run" do
    %w[lib/incident_io/models/gone_v1.rb sig/incident_io/models/gone_v1.rbs].each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@dir, path)))
      File.write(File.join(@dir, path), "")
    end

    described_class.new(api, @dir).write

    expect(File).not_to exist(File.join(@dir, "lib/incident_io/models/gone_v1.rb"))
    expect(File).not_to exist(File.join(@dir, "sig/incident_io/models/gone_v1.rbs"))
  end

  it "generates idiomatic methods" do
    described_class.new(api, @dir).write
    source = generated("lib/incident_io/resources/v2/widgets.rb")

    expect(source).to include("def create(name:, idempotency_key: SecureRandom.uuid, part: nil, request_options: {})")
    expect(source).to include("def show(id, request_options: {})")
    expect(source).to include('path("/v2/widgets/%s", id)')
    expect(source).to include('deprecated!("client.v2.widgets.destroy")')
    expect(source).to include("# @param part [Models::PartV2, Hash]")
    expect(source).to include("# Endpoint: `GET /v2/widgets`. Scopes: widgets.read.")
  end

  it "generates models with lazy references" do
    described_class.new(api, @dir).write
    source = generated("lib/incident_io/models/widget_v2.rb")

    expect(source).to include("    WidgetV2 = Model.define(\n      id: :string,\n      class: :string,")
    expect(source).to include("parts: [-> { PartV2 }]")
    expect(source).to include("# @!attribute [r] class_")
  end
  it "generates resource signatures" do
    described_class.new(api, @dir).write
    source = generated("sig/incident_io/resources/v2/widgets.rbs")

    expect(source).to include("def show: (String id, ?request_options: request_options) -> Models::WidgetV2")
    expect(source).to include(<<~RBS.gsub(/^/, "        ").strip)
      def list: (
        kind: Hash[untyped, untyped],
        ?page_size: Integer?,
        ?after: String?,
        ?request_options: request_options
      ) -> Pager[Models::WidgetV2]
    RBS
    expect(source).to include("?part: (Models::PartV2 | Hash[untyped, untyped])?")
    expect(source).to include("?idempotency_key: String,")
    expect(source).to include("# @deprecated\n        def destroy: (String id, ?request_options: request_options) -> nil")
    expect(source).to include("-> String") # CSV export
  end

  it "generates model signatures" do
    described_class.new(api, @dir).write
    source = generated("sig/incident_io/models/widget_v2.rbs")

    expect(source).to include("class WidgetV2 < ::Data")
    expect(source).to include("attr_reader class_: String?")
    expect(source).to include("attr_reader created_at: Time?")
    expect(source).to include("attr_reader parts: Array[PartV2]?")
    expect(source).to include("attr_reader labels: Hash[String, String]?")
    expect(source).to include("?raw: Hash[String, untyped]?")
    expect(source).to include("def self.from_api: (nil) -> nil")
  end
  it "generates the webhook event and audit log maps" do
    described_class.new(api, @dir).write

    expect(generated("lib/incident_io/webhook_events.rb"))
      .to include(%(# Widget created.\n      "public_widget.created_v1" => :WidgetV2\n))
    expect(generated("sig/incident_io/webhook_events.rbs")).to include("type data = Models::WidgetV2")
    expect(generated("lib/incident_io/audit_log_entries.rb"))
      .to include(%(["widget.deleted", 2] => :AuditLogsWidgetDeletedV2\n))
    expect(generated("sig/incident_io/audit_log_entries.rbs")).to include("type entry = Models::AuditLogsWidgetDeletedV2")
  end
end
