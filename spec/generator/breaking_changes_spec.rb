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

  # Gives the widget and the create payload a `box` with a `size` key and
  # the given other keys inside it, and the filter arguments of the list
  # method their operators. `attrs` is a filter whose operators are only
  # shown in an example.
  def with_nested(spec, sizes:, kind:, after: nil, attrs: %w[one_of], keys: {})
    box = {"type" => "object", "properties" => {"size" => {"type" => "string", "enum" => sizes}.compact, **keys}}
    %w[WidgetV2 WidgetsCreatePayloadV2].each { |model| spec["components"]["schemas"][model]["properties"]["box"] = box }
    list = spec["paths"]["/v2/widgets"]["get"]["parameters"]
    list[2]["description"] = "Filter on kind. #{kind}"
    list[1]["description"] = after
    list << {"in" => "query", "name" => "attrs", "style" => "deepObject", "schema" => {
      "type" => "object", "example" => {"01ABC" => attrs.to_h { |operator| [operator, ["x"]] }}
    }}
    spec
  end

  # Generates code from a spec into its own root and returns the root.
  def generate(name, spec)
    File.join(@dir, name).tap { |root| IncidentIoGenerator::Writer.new(IncidentIoGenerator::Api.new(spec), root).write }
  end

  # The mini spec before a breaking update. It has an extra event, entry,
  # model, field and method, a field of another type, fields and an
  # argument that allow other values, a box with other keys and a key of
  # another type, and methods with other arguments, argument types and
  # return types.
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
      schemas["WidgetsCreatePayloadV2"]["properties"]["colour"] = {"type" => "string", "description" => "The accepted operator is 'is'."}
      with_nested(spec, sizes: %w[s m l], kind: "The accepted operators are 'one_of', or 'not_in'.", after: "The accepted operator is 'is'.",
        attrs: %w[one_of not_in], keys: {
          "colour" => {"type" => "string", "enum" => %w[red blue]},
          "inner" => {"type" => "object", "properties" => {"a" => {"type" => "string"}}},
          "depth" => {"type" => "integer"},
          "tone" => {"type" => "string", "enum" => %w[warm cool]},
          "lid" => {"type" => "object", "properties" => {"hinge" => {"type" => "string", "enum" => %w[left right]}}}
        })
      schemas["WidgetsCreatePayloadV2"]["properties"]["crate"] = {"type" => "object", "properties" => {"w" => {"type" => "string"}}}
      schemas["WidgetV2"]["properties"]["kind"]["enum"] = %w[big tiny]
      schemas["WidgetV2"]["properties"]["class"]["enum"] = %w[a b]
      schemas["WidgetV2"]["properties"]["labels"]["additionalProperties"]["enum"] = %w[hot cold]
      schemas["WidgetsCreatePayloadV2"]["properties"]["name"]["enum"] = %w[red green blue]

      spec["x-webhooks"]["/x-webhooks/public_widget.deleted_v1"] = event("WidgetDeletedBody", "Widget deleted.")
      spec["x-webhooks"]["/x-audit-logs/widget.created.1"] = event("AuditLogsWidgetDeletedV2", "Widget created.")
      # An event and an entry type that the newer spec gives another model.
      schemas["WidgetCreatedBody"]["properties"]["public_widget.created_v1"] = {"$ref" => "#/components/schemas/PartV2"}
      spec["x-webhooks"]["/x-audit-logs/widget.deleted.2"] = event("PartV2", "Widget deleted.")

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

  # The mini spec after the update, with fields and arguments limited to
  # some values, and one operator fewer. Its box lost two keys, gained one,
  # has a limit on another and one of another type. It has a new version
  # of the widgets resource with one method.
  def newer_spec
    mini_spec.tap do |spec|
      with_nested(spec, sizes: %w[s m], kind: "The accepted operator is 'one_of'.", keys: {
        "depth" => {"type" => "integer", "enum" => [1, 2]},
        "tone" => {"type" => "string"},
        "lid" => {"type" => "integer"},
        "shape" => {"type" => "string", "enum" => %w[round]}
      })
      schemas = spec["components"]["schemas"]
      schemas["WidgetsCreatePayloadV2"]["properties"]["crate"] = {"$ref" => "#/components/schemas/PartV2"}
      schemas["WidgetV2"]["properties"]["labels"]["additionalProperties"]["enum"] = %w[hot]
      schemas["WidgetsCreatePayloadV2"]["properties"]["name"]["enum"] = %w[red green]
      spec["paths"]["/v2/widgets"]["get"]["parameters"][0]["schema"]["enum"] = [25, 50]
      spec["paths"]["/v3/widgets/{uid}"] = {
        "get" => operation("Widgets V3#Show", "WidgetsShowResultV2", parameters: [path_param("uid")])
      }
    end
  end

  it "lists what the newer code removed or changed" do
    report = described_class.report(generate("before", older_spec), generate("after", newer_spec))

    expect(report).to eq(<<~MARKDOWN)
      ## Breaking changes

      The latest spec removes or changes these. Each one can break code that uses the gem.

      - Webhook event `public_widget.created_v1` changed its model from `PartV2` to `WidgetV2`
      - Webhook event `public_widget.deleted_v1` was removed
      - Audit log entry `widget.created` (version 1) was removed
      - Audit log entry `widget.deleted` (version 2) changed its model from `PartV2` to `AuditLogsWidgetDeletedV2`
      - Model `GadgetV1` was removed
      - Model `WidgetDeletedBody` was removed
      - Field `PartV2#id` changed type from `Integer` to `String`
      - Field `WidgetCreatedBody#public_widget_created_v1` changed type from `PartV2` to `WidgetV2`
      - Field `WidgetV2#colour` was removed
      - Field `WidgetV2#box.colour` was removed
      - Field `WidgetV2#box.inner` was removed
      - Field `WidgetV2#box.lid` changed type from `Hash` to `Integer`
      - Field `WidgetsCreatePayloadV2#colour` was removed
      - Field `WidgetsCreatePayloadV2#box.colour` was removed
      - Field `WidgetsCreatePayloadV2#box.inner` was removed
      - Field `WidgetsCreatePayloadV2#box.lid` changed type from `Hash` to `Integer`
      - Field `WidgetsCreatePayloadV2#crate` changed type from `Hash` to `PartV2`
      - Field `WidgetV2#labels` no longer allows `cold`
      - Field `WidgetV2#kind` no longer allows `tiny`
      - Field `WidgetV2#box.size` no longer allows `l` (same in `WidgetsCreatePayloadV2`)
      - Field `WidgetV2#box.depth` now only allows `1`, `2` (same in `WidgetsCreatePayloadV2`)
      - Field `WidgetsCreatePayloadV2#name` no longer allows `blue`
      - Resource `client.widgets` now uses v3 instead of v2
      - Method `client.widgets.archive` was removed
      - Method `client.widgets.create` was removed
      - Method `client.widgets.destroy` was removed
      - Method `client.widgets.export` was removed
      - Method `client.widgets.list` was removed
      - Method `client.widgets.show` changed its positional arguments from `(id)` to `(uid)`
      - Method `client.v2.widgets.archive` was removed
      - Method `client.v2.widgets.create` no longer takes `colour:`
      - Method `client.v2.widgets.create` no longer takes `box.colour`
      - Method `client.v2.widgets.create` no longer takes `box.inner`
      - Method `client.v2.widgets.create` now needs `name:`
      - Method `client.v2.widgets.create` changed the type of argument `box.lid` from `Hash` to `Integer`
      - Method `client.v2.widgets.create` changed the type of argument `crate` from `Hash` to `Models::PartV2, Hash`
      - Method `client.v2.widgets.create` no longer allows `blue` for `name`
      - Method `client.v2.widgets.create` no longer allows `l` for `box.size`
      - Method `client.v2.widgets.create` now only allows `1`, `2` for `box.depth`
      - Method `client.v2.widgets.destroy` changed what it returns from `Models::WidgetV2` to `nil`
      - Method `client.v2.widgets.export` changed its positional arguments from `(shelf_id, id)` to `(id)`
      - Method `client.v2.widgets.list` changed the type of argument `page_size` from `String` to `Integer`
      - Method `client.v2.widgets.list` now only allows `25`, `50` for `page_size`
      - Method `client.v2.widgets.list` no longer allows `not_in` as an operator for `kind`
      - Method `client.v2.widgets.list` no longer says which operators `after` allows
      - Method `client.v2.widgets.list` no longer shows `not_in` as an operator for `attrs` in its examples
      - Field `WidgetV2#class_` now allows any value
      - Field `WidgetV2#kind` now also allows `small`
      - Field `WidgetV2#box.tone` now allows any value
    MARKDOWN
  end

  it "is empty when things were only added, made optional or allow more" do
    before = mini_spec.tap do |spec|
      with_nested(spec, sizes: nil, kind: "The accepted operator is 'one_of'.")
      list = spec["paths"]["/v2/widgets"]["get"]["parameters"]
      list[0]["schema"]["enum"] = [25]
      list[1]["schema"]["enum"] = %w[start]
      spec["components"]["schemas"]["WidgetsCreatePayloadV2"]["properties"]["name"]["enum"] = %w[red]
    end
    after = mini_spec.tap do |spec|
      with_nested(spec, sizes: nil, kind: "The accepted operators are 'one_of', or 'not_in'.", after: "The accepted operator is 'is'.",
        attrs: %w[one_of not_in], keys: {"shape" => {"type" => "string", "enum" => %w[round]}})
      schemas = spec["components"]["schemas"]
      schemas["GadgetV1"] = {"type" => "object"}
      schemas["WidgetV2"]["properties"]["colour"] = {"type" => "string"}
      schemas["WidgetsCreatePayloadV2"]["required"] = ["idempotency_key"]
      schemas["WidgetsCreatePayloadV2"]["properties"]["colour"] = {"type" => "string", "enum" => %w[red]}
      # Code can't be handed a payload, so more values for its fields
      # can't break anything.
      schemas["WidgetsCreatePayloadV2"]["properties"]["name"]["enum"] = %w[red green]
      spec["paths"]["/v2/widgets"]["get"]["parameters"][0]["schema"]["enum"] = [25, 50]
    end

    expect(described_class.report(generate("before", before), generate("after", after))).to eq("")
  end

  it "checks example operators against the ones the spec now names or shows" do
    was = {shown: {
      "gone" => %w[one_of], "named" => %w[one_of], "narrowed" => %w[one_of not_in],
      "kept" => %w[one_of not_in], "bare" => %w[one_of]
    }}
    now = {
      types: {"named" => "Hash", "narrowed" => "Hash", "kept" => "Hash", "bare" => "Hash"},
      operators: {"named" => %w[one_of is], "narrowed" => %w[one_of]},
      shown: {"kept" => %w[one_of]}
    }

    expect(described_class.example_changes("client.v2.widgets.list", was, now)).to eq([
      "Method `client.v2.widgets.list` no longer allows `not_in` as an operator for `narrowed`",
      "Method `client.v2.widgets.list` no longer shows `not_in` as an operator for `kept` in its examples",
      "Method `client.v2.widgets.list` no longer shows `one_of` as an operator for `bare` in its examples"
    ])
  end

  it "leaves out resources that are gone or still use the same version" do
    before = {"gone" => {version: "v1", methods: {}}, "kept" => {version: "v2", methods: {}}}
    after = {"kept" => {version: "v2", methods: {}}, "added" => {version: "v1", methods: {}}}

    expect(described_class.accessor_changes(before, after)).to eq([])
  end

  it "names the models that share a change on one line" do
    changes = %w[A B C D E].map { |model| [model, "event_type", "now also allows `x`"] } +
      [["A", "kind", "now also allows `x`"], ["B", "event_type", "no longer allows `y`"]]

    expect(described_class.together(changes)).to eq([
      "Field `A#event_type` now also allows `x` (same in `B`, `C`, `D` and 1 more)",
      "Field `A#kind` now also allows `x`",
      "Field `B#event_type` no longer allows `y`"
    ])
  end

  it "knows which models code can be handed" do
    surface = described_class.surface(generate("code", mini_spec))

    expect(surface[:read]).to match_array(%w[WidgetV2 PartV2 AuditLogsWidgetDeletedV2])
  end

  it "stops at the limit and counts the rest" do
    stub_const("#{described_class}::LIMIT", 2)

    report = described_class.report(generate("before", older_spec), generate("after", newer_spec))

    expect(report.lines.last(3)).to eq([
      "- Webhook event `public_widget.created_v1` changed its model from `PartV2` to `WidgetV2`\n",
      "- Webhook event `public_widget.deleted_v1` was removed\n",
      "- and 47 more\n"
    ])
  end

  describe "the real generated code" do
    let(:surface) { described_class.surface(IncidentIoGenerator::ROOT) }

    it "has every event and entry type read with its model" do
      events = IncidentIo::Webhook::EVENTS.to_h { |type, model| ["`#{type}`", model.to_s] }
      entries = IncidentIo::AuditLog::ENTRIES.to_h { |(action, version), model| ["`#{action}` (version #{version})", model.to_s] }

      expect(surface[:events]).to eq(events)
      expect(surface[:entries]).to eq(entries)
    end

    it "has every model and field read" do
      models = IncidentIo::Models.constants.to_h { |name| [name.to_s, IncidentIo::Models.const_get(name).members.map(&:to_s)] }
      # A name with a dot is a key inside a field.
      fields = surface[:models].transform_values { |model| model[:types].keys.reject { |name| name.include?(".") } }

      expect(fields).to eq(models)
      expect(surface[:models].values.flat_map { |model| model[:types].values }).to all(match(/\A[A-Z]/))
    end

    it "has the type of every key inside a field or an argument" do
      attachment = surface[:models].fetch("IncidentAttachmentsCreatePayloadV1")[:types]
      create = surface[:methods].fetch("client.v1.incident_attachments.create")[:types]

      expect(attachment).to include("resource" => "Hash", "resource.resource_type" => "String", "resource.url" => "String")
      expect(create).to include("resource" => "Hash", "resource.resource_type" => "String", "resource.url" => "String")
      # Each key sits in a field or a key that is read too.
      [*surface[:models].values, *surface[:methods].values].each do |owner|
        expect(described_class.comparable(owner[:types], owner[:types])).to eq(owner[:types].keys)
      end
    end

    it "knows which version of each resource the client uses" do
      client = IncidentIo::Client.new(api_key: "k")
      # Leaves out the version accessors, and the copies of each method that
      # rbs test adds, which have "__" in their names.
      accessors = IncidentIo::Resources::Accessors.public_instance_methods(false).grep_v(/\Av\d+\z|__/)

      expect(surface[:newest].keys).to match_array(accessors.map(&:to_s))
      surface[:newest].each do |resource, newest|
        expect(client.public_send(resource)).to be(client.public_send(newest[:version]).public_send(resource))
        expect(newest[:methods].keys).to all(start_with("client.#{resource}."))
      end
    end

    it "knows which models code can be handed" do
      expect(surface[:read]).to include("IncidentV2", "UserV2", "WebhookPrivateResourceV2", "AuditLogsAlertRouteCreatedV1")
      expect(surface[:read]).not_to include("IncidentsCreatePayloadV2", "WebhooksPrivateAlertCreatedV1ResponseBody")
      expect(surface[:models].keys).to include(*surface[:read])
    end

    it "has limits and operators only for fields and arguments it read" do
      allowed = JSON.parse(File.read(File.join(IncidentIoGenerator::ROOT, described_class::VALUES_PATH)))
      expect(allowed.values).to all(satisfy { |limits| !limits.empty? })
      # A limit has the same name as the field, argument or key it is on,
      # e.g. "resource.resource_type".
      allowed["fields"].each { |model, fields| expect(surface[:models].fetch(model)[:types].keys).to include(*fields.keys) }
      allowed.values_at("arguments", "operators", "example_operators").each do |limits|
        limits.each { |call, args| expect(surface[:methods].fetch(call)[:types].keys).to include(*args.keys) }
      end
      expect(surface[:models].values.sum { |model| model[:limits].size }).to eq(allowed["fields"].values.sum(&:size))
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
