# frozen_string_literal: true

module IncidentIoGenerator
  class Error < StandardError; end

  # A keyword or positional argument of a generated method.
  Param = Data.define(:name, :required, :schema, :description, :default)

  # What a generated method returns.
  #   kind: :none (no body), :text (e.g. CSV), :json or :paginated
  #   unwrap: response key to return instead of the whole body
  #   model: Ruby source for the `model:` argument, or nil for raw data
  #   items_key: array key for paginated responses
  #   yard: YARD return type
  #   rbs: RBS return type
  Result = Data.define(:kind, :unwrap, :model, :items_key, :yard, :rbs)

  Operation = Data.define(
    :operation_id, :http_method, :path, :method_name, :full_name, :summary, :description,
    :deprecated, :replacement, :scopes, :no_auth, :path_params, :query_params, :body_params,
    :body, :idempotent, :result
  ) do
    def keyword_params
      required, optional = (query_params + body_params).partition(&:required)
      required + optional
    end
  end

  # All operations of one spec tag, e.g. "Incidents V2".
  Resource = Data.define(:tag, :version, :name, :class_name, :description, :operations) do
    def version_number = version.delete_prefix("V").to_i
    def file_path = "resources/#{version.downcase}/#{name}"
  end

  # A webhook event type and the schema of its payload.
  WebhookEvent = Data.define(:type, :description, :model)
  # An audit log entry type and its schema.
  AuditLogEntry = Data.define(:action, :version, :description, :model)

  Field = Data.define(:api_name, :member, :type, :yard, :rbs, :description, :required)
  ModelSchema = Data.define(:name, :file_name, :description, :fields)

  # Reads the OpenAPI spec into the resources and models to generate.
  class Api
    # Methods already on IncidentIo::Client; resources can't use these names.
    CLIENT_METHODS = %w[request execute paginate inspect base_url timeout open_timeout max_retries logger].freeze
    # Methods on IncidentIo::Resource; operations can't use these names.
    RESOURCE_METHODS = (IncidentIo::Resource.instance_methods(false) + IncidentIo::Resource.private_instance_methods(false))
      .map(&:to_s).freeze
    RESERVED_PARAMS = %w[request_options].freeze
    TAG_PATTERN = /\A(?<base>.+) (?<version>V\d+)\z/
    HTTP_METHODS = %w[get post put patch delete].freeze

    attr_reader :resources, :models, :webhook_events, :audit_log_entries

    def initialize(spec, overrides = {})
      @spec = spec
      @schemas = spec.dig("components", "schemas") || {}
      @tag_descriptions = (spec["tags"] || []).to_h { |t| [t["name"], t["description"]] }
      @overrides = overrides.fetch("operations", {})
      @models = build_models
      @resources = build_resources
      @webhook_events, @audit_log_entries = build_events
      check_overrides_used!
    end

    # Resources grouped by version, e.g. { "V1" => [...], "V2" => [...] }.
    def versions
      resources.group_by(&:version).sort_by { |v, _| v.delete_prefix("V").to_i }.to_h
    end

    # The newest version of each resource, keyed by accessor name.
    def latest_resources
      @latest_resources ||= resources.group_by(&:name)
        .transform_values { |rs| rs.max_by(&:version_number) }
        .sort.to_h
    end

    private

    def build_models
      models = @schemas.sort.map do |name, schema|
        required = schema["required"] || []
        fields = (schema["properties"] || {}).map do |api_name, prop|
          Field.new(
            api_name:,
            member: IncidentIo::Model.member_name(api_name).to_s,
            type: Types.model_type(prop),
            yard: Types.yard_type(prop, namespace: ""),
            rbs: Types.rbs_type(prop, namespace: ""),
            description: describe(prop),
            required: required.include?(api_name)
          )
        end
        ModelSchema.new(name:, file_name: Naming.underscore(name), description: schema["description"], fields:)
      end

      duplicates = models.group_by(&:file_name).select { |_, ms| ms.size > 1 }
      raise Error, "models share a file name: #{duplicates.keys.join(", ")}" if duplicates.any?

      models
    end

    # Webhook events and audit log entries are described under `x-webhooks`,
    # keyed like "/x-webhooks/public_incident.incident_created_v2" and
    # "/x-audit-logs/alert_route.created.1".
    def build_events
      webhook_events = []
      audit_log_entries = []

      (@spec["x-webhooks"] || {}).sort.each do |key, item|
        op = item.fetch("get")
        body = Types.ref_name(op.dig("responses", "200", "content", "application/json", "schema") || {})
        raise Error, "#{key}: no response schema" unless body

        case key
        when %r{\A/x-webhooks/(?<type>.+)\z}
          type = Regexp.last_match(:type)
          payload = Types.ref_name(@schemas.fetch(body).dig("properties", type) || {})
          raise Error, "#{key}: body has no #{type} payload" unless payload

          webhook_events << WebhookEvent.new(type:, description: op["description"], model: payload)
        when %r{\A/x-audit-logs/(?<action>.+)\.(?<version>\d+)\z}
          audit_log_entries << AuditLogEntry.new(
            action: Regexp.last_match(:action), version: Regexp.last_match(:version).to_i,
            description: op["description"], model: body
          )
        else
          raise Error, "unknown x-webhooks entry: #{key}"
        end
      end

      [webhook_events, audit_log_entries]
    end

    def build_resources
      by_tag = Hash.new { |h, k| h[k] = [] }
      each_operation { |path, http_method, op| by_tag[op.fetch("tags").first] << [path, http_method, op] }

      resources = by_tag.sort.map do |tag, entries|
        match = TAG_PATTERN.match(tag) or raise Error, "tag has no version: #{tag.inspect}"
        name = Naming.underscore(match[:base])
        raise Error, "resource name #{name} clashes with a Client method" if CLIENT_METHODS.include?(name)
        raise Error, "resource name #{name} clashes with a version accessor" if name.match?(/\Av\d+\z/)

        operations = entries.map { |path, http_method, op| build_operation(path, http_method, op, name, match[:version]) }
          .sort_by(&:method_name)
        check_unique_methods!(tag, operations)

        Resource.new(
          tag:, version: match[:version], name:, class_name: Naming.camelize(match[:base]),
          description: @tag_descriptions[tag], operations:
        )
      end

      add_replacements(resources).sort_by { |r| [r.version_number, r.name] }
    end

    def each_operation
      @spec.fetch("paths").each do |path, item|
        item.each do |http_method, op|
          yield path, http_method, op if HTTP_METHODS.include?(http_method)
        end
      end
    end

    def build_operation(path, http_method, op, resource_name, version)
      id = op.fetch("operationId")
      override = @overrides.fetch(id, {})
      @used_overrides ||= []
      @used_overrides << id if @overrides.key?(id)

      action = id.split("#")[1] or raise Error, "operationId has no action: #{id}"
      method_name = override.fetch("method", Naming.underscore(action))
      raise Error, "#{id}: method name #{method_name} clashes with a Resource helper" if RESOURCE_METHODS.include?(method_name)

      params = op["parameters"] || []
      path_params = path.scan(/\{(\w+)\}/).flatten.map do |name|
        param = params.find { |p| p["in"] == "path" && p["name"] == name } or raise Error, "#{id}: no path param #{name}"
        build_param(param, required: true)
      end
      query_params = params.select { |p| p["in"] == "query" }.map { |p| build_param(p, required: p["required"] == true) }

      body_schema = resolve(op.dig("requestBody", "content", "application/json", "schema"))
      body_params = body_params(body_schema)
      idempotent = body_params.any? { |p| p.name == "idempotency_key" }

      check_params!(id, path_params + query_params + body_params)

      Operation.new(
        operation_id: id,
        http_method:,
        path:,
        method_name:,
        full_name: "client.#{version.downcase}.#{resource_name}.#{method_name}",
        summary: op["summary"],
        description: op["description"],
        deprecated: op["deprecated"] == true,
        replacement: nil,
        scopes: op["x-rbac-scopes"] || [],
        no_auth: op["security"] == [],
        path_params:,
        query_params:,
        body_params:,
        body: !body_schema.nil?,
        idempotent:,
        result: build_result(id, op, query_params)
      )
    end

    def build_param(param, required:)
      schema = param["schema"] || {}
      Param.new(
        name: param.fetch("name"),
        required:,
        schema:,
        description: describe(schema, param["description"]),
        default: nil
      )
    end

    def body_params(schema)
      return [] if schema.nil?

      required = schema["required"] || []
      (schema["properties"] || {}).map do |name, prop|
        # Generated per call so retries of the same call reuse the key.
        if name == "idempotency_key"
          Param.new(name:, required: false, schema: prop, description: describe(prop), default: "SecureRandom.uuid")
        else
          Param.new(name:, required: required.include?(name), schema: prop, description: describe(prop), default: nil)
        end
      end
    end

    def build_result(id, op, query_params)
      code, response = (op["responses"] || {}).find { |c, _| c.start_with?("2") }
      raise Error, "#{id}: no 2xx response" unless code

      content = response["content"] || {}
      json = content.dig("application/json", "schema")
      unless json
        return Result.new(kind: :none, unwrap: nil, model: nil, items_key: nil, yard: "nil", rbs: "nil") if content.empty?

        return Result.new(kind: :text, unwrap: nil, model: nil, items_key: nil, yard: "String", rbs: "String")
      end

      schema = resolve(json)
      props = schema["properties"] || {}

      if props.key?("pagination_meta") && query_params.any? { |p| p.name == "after" }
        arrays = props.select { |k, v| k != "pagination_meta" && v["type"] == "array" }
        raise Error, "#{id}: paginated response needs exactly one array, got #{arrays.keys}" unless arrays.size == 1

        items_key, items = arrays.first
        item_type = Types.result_type(items["items"])
        Result.new(kind: :paginated, unwrap: nil, model: item_type, items_key:,
          yard: "IncidentIo::Pager<#{Types.yard_type(items["items"])}>",
          rbs: "Pager[#{Types.rbs_result(items["items"])}]")
      elsif props.size == 1
        key, prop = props.first
        Result.new(kind: :json, unwrap: key, model: Types.result_type(prop), items_key: nil,
          yard: Types.yard_type(prop), rbs: Types.rbs_result(prop))
      else
        Result.new(kind: :json, unwrap: nil, model: Types.result_type(json), items_key: nil,
          yard: Types.yard_type(json), rbs: Types.rbs_result(json))
      end
    end

    # Points deprecated operations at the same method on the newest version
    # of their resource, when there is one.
    def add_replacements(resources)
      latest = resources.group_by(&:name).transform_values { |rs| rs.max_by(&:version_number) }

      resources.map do |resource|
        newest = latest.fetch(resource.name)
        operations = resource.operations.map do |op|
          next op unless op.deprecated && newest != resource

          same = newest.operations.find { |o| o.method_name == op.method_name }
          op.with(replacement: same ? "client.#{newest.name}.#{same.method_name}" : "client.#{newest.name}")
        end
        resource.with(operations:)
      end
    end

    def check_params!(id, params)
      params.each do |p|
        raise Error, "#{id}: parameter #{p.name.inspect} is not a safe Ruby name" unless Naming.safe_identifier?(p.name)
        raise Error, "#{id}: parameter #{p.name.inspect} is reserved" if RESERVED_PARAMS.include?(p.name)
      end

      duplicates = params.map(&:name).tally.select { |_, n| n > 1 }.keys
      raise Error, "#{id}: parameter names used twice: #{duplicates.join(", ")}" if duplicates.any?
    end

    def check_unique_methods!(tag, operations)
      duplicates = operations.group_by(&:method_name).select { |_, ops| ops.size > 1 }
      return if duplicates.empty?

      details = duplicates.map { |name, ops| "#{name} (#{ops.map(&:operation_id).join(", ")})" }
      raise Error, "#{tag}: methods share a name, add an override: #{details.join("; ")}"
    end

    def check_overrides_used!
      unused = @overrides.keys - (@used_overrides || [])
      raise Error, "overrides for unknown operations: #{unused.join(", ")}" if unused.any?
    end

    def resolve(schema)
      return nil if schema.nil?

      ref = Types.ref_name(schema)
      ref ? @schemas.fetch(ref) : schema
    end

    def describe(schema, fallback = nil)
      text = schema["description"] || fallback
      text = text.to_s.gsub(/\s+/, " ").strip
      enum = schema["enum"] || schema.dig("items", "enum")
      text = [text, "One of: #{enum.join(", ")}."].reject(&:empty?).join(" ") if enum
      text.empty? ? nil : text
    end
  end
end
