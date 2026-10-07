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
      "spec/fixtures/operations.json", "spec/fixtures/allowed_values.json",
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

    expect(source).to include("def create(name:, idempotency_key: SecureRandom.uuid, part: NOT_GIVEN, request_options: {})")
    expect(source).to include("body: given({name:, idempotency_key:, part:}),")
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
    expect(source).to include("?part: (Models::PartV2 | Hash[untyped, untyped] | NotGiven)?")
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
  it "writes the values and operators that fields and arguments are limited to" do
    spec = mini_spec
    spec["paths"]["/v2/widgets"]["get"]["parameters"][0]["schema"]["enum"] = [25, 50]
    spec["paths"]["/v2/widgets"]["get"]["parameters"][2]["description"] = "The accepted operators are 'one_of', or 'not_in'."
    list = spec["paths"]["/v2/widgets"]["get"]
    list["description"] = "Try `--data 'attrs[ABC][not_in]=x'`."
    list["parameters"] << {"in" => "query", "name" => "attrs", "style" => "deepObject", "schema" => {
      "type" => "object", "example" => {"01ABC" => {"one_of" => ["x"]}}
    }}
    list["parameters"] << {"in" => "query", "name" => "anything", "style" => "deepObject", "schema" => {"type" => "object"}}
    schemas = spec["components"]["schemas"]
    schemas["WidgetV2"]["properties"]["labels"]["additionalProperties"]["enum"] = %w[hot cold]
    schemas["WidgetV2"]["properties"]["box"] = {"type" => "object", "properties" => {"size" => {"type" => "string", "enum" => %w[s m]}}}
    described_class.new(IncidentIoGenerator::Api.new(spec), @dir).write

    expect(JSON.parse(generated("spec/fixtures/allowed_values.json"))).to eq(
      "fields" => {"WidgetV2" => {"kind" => %w[big small], "labels" => %w[hot cold], "box.size" => %w[s m]}},
      "arguments" => {"client.v2.widgets.list" => {"page_size" => [25, 50]}},
      "operators" => {"client.v2.widgets.list" => {"kind" => %w[one_of not_in]}},
      "example_operators" => {"client.v2.widgets.list" => {"attrs" => %w[one_of not_in]}}
    )
  end

  it "writes a manifest of what each resource method should do" do
    described_class.new(api, @dir).write
    manifest = JSON.parse(generated("spec/fixtures/operations.json")).to_h { |op| [op["method"], op] }

    expect(manifest["create"]).to include(
      "operation_id" => "Widgets V2#Create", "call" => "client.v2.widgets.create", "version" => "v2", "resource" => "widgets",
      "http_method" => "post", "path" => "/v2/widgets", "path_args" => [],
      "keyword_args" => {"name" => "name-value"},
      "arg_types" => {"name" => "String", "idempotency_key" => "String", "part" => "Models::PartV2, Hash"},
      "returns" => "Models::WidgetV2",
      "body_keys" => ["name"], "body" => true, "null_body_key" => "part",
      "idempotency_key" => true,
      "result" => {"kind" => "json", "unwrap" => "widget", "items_key" => nil, "model" => "WidgetV2", "depth" => 0}
    )
    expect(manifest["list"]).to include(
      "keyword_args" => {"kind" => {"one_of" => ["kind-value"]}},
      "arg_types" => {"kind" => "Hash", "page_size" => "Integer", "after" => "String"},
      "returns" => "IncidentIo::Pager<Models::WidgetV2>",
      "query_keys" => ["kind"],
      "result" => include("kind" => "paginated", "items_key" => "widgets", "model" => "WidgetV2")
    )
    expect(manifest["show"]).to include("path" => "/v2/widgets/{id}", "path_args" => ["id-value"], "arg_types" => {"id" => "String"})
    expect(manifest["destroy"]).to include("deprecated" => true, "body" => false, "result" => include("kind" => "none"))
    expect(manifest["export"]["result"]).to include("kind" => "text")
  end

  describe "helpers" do
    let(:writer) { described_class.new(api, @dir) }
    let(:ops) { api.resources.first.operations.to_h { |op| [op.method_name, op] } }

    it "documents scopes, deprecations and endpoints without an API key" do
      no_auth = ops["show"].with(scopes: [], no_auth: true, deprecated: true, replacement: "client.widgets.find")

      docs = writer.method_docs(no_auth, 0)

      expect(docs).not_to include("Scopes:")
      expect(docs).to include("Does not use your API key")
      expect(docs).to include("@deprecated Use `client.widgets.find` instead.")
      expect(writer.method_docs(ops["destroy"], 0)).to include("@deprecated incident.io has deprecated this endpoint.")
    end

    it "splits long signatures and hashes over several lines" do
      long = ops["list"].with(method_name: "a_method_with_a_very_long_name_that_goes_on_and_on_and_on_and_on")

      expect(writer.signature(long, 8)).to include("(\n")
      expect(writer.hash_expression(ops["create"].body_params, 90)).to start_with("{\n")
      expect(writer.hash_expression([], 0)).to eq("{}")
      expect(writer.one_per_line("{", [], "}.freeze", 4)).to eq("{}.freeze")
    end

    it "writes paginated calls without a query or model, and bodies without fields" do
      bare_list = ops["list"].with(query_params: [], result: ops["list"].result.with(model_name: nil))
      empty_body = ops["create"].with(body_params: [])

      expect(writer.call(bare_list, 0)).not_to include("query:", "model:")
      expect(writer.call(empty_body, 0)).to include("body: {},")
      expect(writer.call(ops["list"].with(result: ops["show"].result), 0)).to include("query: {page_size:, after:, kind:}")
    end

    it "puts a one-line summary before a longer description" do
      op = ops["show"].with(description: "Shows a widget. Includes its parts.")

      expect(writer.method_docs(op, 0)).to start_with("# Shows a widget\n#\n# Shows a widget. Includes its parts.\n#\n")
      expect(writer.method_docs(ops["show"], 0)).to start_with("# Does Widgets V2#Show\n#\n# Endpoint:")
    end

    it "makes one-line summaries" do
      expect(writer.summary("Create a new incident.\n\nMore detail.", "x")).to eq("Create a new incident")
      expect(writer.summary("Lists these:", "x")).to eq("Lists these")
      expect(writer.summary(nil, "The id field")).to eq("The id field")

      long = writer.summary("word " * 30, "x")
      expect(long.length).to be < 80
      expect(long).to end_with("word…")
    end

    it "handles sentences" do
      expect(writer.sentence("Done.")).to eq("Done.")
      expect(writer.sentence("Done")).to eq("Done.")
      expect(writer.first_sentence(nil)).to be_nil
    end
  end

  describe "IncidentIoGenerator.generate" do
    it "reads the spec and overrides from files and writes to a root" do
      spec_path = File.join(@dir, "spec.json")
      overrides_path = File.join(@dir, "overrides.yml")
      File.write(spec_path, JSON.generate(mini_spec))
      File.write(overrides_path, {"operations" => {"Widgets V2#Export" => {"method" => "export_csv"}}}.to_yaml)

      files = IncidentIoGenerator.generate(root: File.join(@dir, "out"), spec_path:, overrides_path:)

      expect(files).to include("lib/incident_io/resources/v2/widgets.rb")
      expect(File.read(File.join(@dir, "out/lib/incident_io/resources/v2/widgets.rb"))).to include("def export_csv(")
    end

    it "works without an overrides file" do
      spec_path = File.join(@dir, "spec.json")
      File.write(spec_path, JSON.generate(mini_spec))

      api = IncidentIoGenerator.load_api(spec_path:, overrides_path: File.join(@dir, "missing.yml"))

      expect(api.resources.first.operations.map(&:method_name)).to include("export")
    end
  end
end
