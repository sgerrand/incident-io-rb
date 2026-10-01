# frozen_string_literal: true

module IncidentIoGenerator
  class Error < StandardError; end

  # A keyword or positional argument of a generated method.
  #   location: :path, :query or :body
  #   default: Ruby source for a generated default, e.g. "SecureRandom.uuid"
  Param = Data.define(:name, :location, :required, :schema, :description, :default) do
    # Optional body arguments default to NOT_GIVEN so that nil can be sent as
    # null; optional query arguments default to nil, which is left out.
    def not_given? = location == :body && !required && !default
  end

  # What a generated method returns.
  #   kind: :none (no body), :text (e.g. CSV), :json or :paginated
  #   yard: YARD return type
  #   unwrap: response key to return instead of the whole body
  #   model_name: schema the result is built with, or nil for raw data
  #   depth: how many arrays model_name is nested in, e.g. 1 for an array
  #   items_key: array key for paginated responses
  Result = Data.define(:kind, :yard, :unwrap, :model_name, :depth, :items_key) do
    def initialize(kind:, yard:, unwrap: nil, model_name: nil, depth: 0, items_key: nil) = super

    # Ruby source for the `model:` argument, or nil for raw data.
    def model
      model_name && nested("[", "]")
    end

    # RBS return type.
    def rbs
      case kind
      when :none then "nil"
      when :text then "String"
      else
        item = model_name ? nested("Array[", "]") : "untyped"
        (kind == :paginated) ? "Pager[#{item}]" : item
      end
    end

    private

    # The model's name wrapped in depth pairs of open and close.
    def nested(open, close)
      "#{open * depth}Models::#{model_name}#{close * depth}"
    end
  end

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
  AuditLogEntry = Data.define(:action, :version, :model)

  Field = Data.define(:api_name, :member, :type, :yard, :rbs, :description)
  ModelSchema = Data.define(:name, :file_name, :description, :fields)

  # Reads the OpenAPI spec into the resources and models to generate.
  class Api
    # Methods already on IncidentIo::Client, public and private; resources
    # can't use these names. Kept by hand because Client needs the generated
    # code to load.
    CLIENT_METHODS = %w[
      request execute paginate inspect base_url timeout open_timeout max_retries logger
      initialize with_retries perform retry_delay backoff build_url build_headers normalize_options redact log
      resource_cache
    ].freeze
    # Public and private instance method names of a class, with or without
    # the ones it inherits.
    def self.method_names(klass, inherited:)
      (klass.instance_methods(inherited) + klass.private_instance_methods(inherited)).map(&:to_s).uniq.freeze
    end

    # Methods on IncidentIo::Resources::Namespace, including those from
    # Object; resources can't use these names.
    NAMESPACE_METHODS = method_names(IncidentIo::Resources::Namespace, inherited: true)
    # Methods on IncidentIo::Resource; operations can't use these names.
    RESOURCE_METHODS = method_names(IncidentIo::Resource, inherited: false)
    # Constants the generated version modules already use; resources can't
    # use these class names.
    RESERVED_CLASS_NAMES = %w[Namespace Resources].freeze
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
    # Resources are already sorted by version, and group_by keeps that order.
    def versions
      resources.group_by(&:version)
    end

    # The newest version of each resource, keyed by accessor name.
    def latest_resources
      @latest_resources ||= newest_by_name(resources).sort.to_h
    end

    private

    def build_models
      models = @schemas.sort.map do |name, schema|
        fields = (schema["properties"] || {}).map do |api_name, prop|
          Field.new(
            api_name:,
            member: IncidentIo::Model.member_name(api_name).to_s,
            type: Types.model_type(prop),
            yard: Types.yard_type(prop, namespace: ""),
            rbs: Types.rbs_type(prop, namespace: ""),
            description: describe(prop)
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
            action: Regexp.last_match(:action), version: Regexp.last_match(:version).to_i, model: body
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
        raise Error, "resource name #{name} clashes with a Namespace method" if NAMESPACE_METHODS.include?(name)
        raise Error, "resource name #{name} clashes with a version accessor" if name.match?(/\Av\d+\z/)
        class_name = Naming.camelize(match[:base])
        raise Error, "resource class name #{class_name} is reserved" if RESERVED_CLASS_NAMES.include?(class_name)

        operations = entries.map { |path, http_method, op| build_operation(path, http_method, op, name, match[:version]) }
          .sort_by(&:method_name)
        check_unique_methods!(tag, operations)

        Resource.new(
          tag:, version: match[:version], name:, class_name:,
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

      action = id.split("#")[1] or raise Error, "operationId has no action: #{id}"
      method_name = override.fetch("method", Naming.underscore(action))
      raise Error, "#{id}: method name #{method_name} clashes with a Resource helper" if RESOURCE_METHODS.include?(method_name)

      params = op["parameters"] || []
      path_params = path.scan(/\{(\w+)\}/).flatten.map do |name|
        param = params.find { |p| p["in"] == "path" && p["name"] == name } or raise Error, "#{id}: no path param #{name}"
        build_param(param, location: :path, required: true)
      end
      query_params = params.select { |p| p["in"] == "query" }
        .map { |p| build_param(p, location: :query, required: p["required"] == true) }

      body_schema = resolve(op.dig("requestBody", "content", "application/json", "schema"))
      body_params = body_params(body_schema)
      idempotent = body_params.any? { |p| p.name == "idempotency_key" }

      check_params!(id, path_params + query_params + body_params)

      result = build_result(id, op, query_params)
      # Pager only sends GETs with a query, so it can't send a body.
      if result.kind == :paginated && (http_method != "get" || body_schema)
        raise Error, "#{id}: paginated operations must be GETs without a body"
      end

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
        result:
      )
    end

    def build_param(param, location:, required:)
      schema = param["schema"] || {}
      Param.new(
        name: param.fetch("name"),
        location:,
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
        # The idempotency key is generated per call so retries of the same
        # call reuse it.
        idempotency_key = name == "idempotency_key"
        Param.new(
          name:, location: :body, required: !idempotency_key && required.include?(name), schema: prop,
          description: describe(prop), default: ("SecureRandom.uuid" if idempotency_key)
        )
      end
    end

    def build_result(id, op, query_params)
      code, response = (op["responses"] || {}).find { |c, _| c.start_with?("2") }
      raise Error, "#{id}: no 2xx response" unless code

      content = response["content"] || {}
      json = content.dig("application/json", "schema")
      unless json
        return Result.new(kind: :none, yard: "nil") if content.empty?

        return Result.new(kind: :text, yard: "String")
      end

      schema = resolve(json)
      props = schema["properties"] || {}

      if props.key?("pagination_meta") && query_params.any? { |p| p.name == "after" }
        arrays = props.select { |k, v| k != "pagination_meta" && v["type"] == "array" }
        raise Error, "#{id}: paginated response needs exactly one array, got #{arrays.keys}" unless arrays.size == 1

        items_key, items = arrays.first
        Result.new(kind: :paginated, items_key:, **Types.result_model(items["items"]),
          yard: "IncidentIo::Pager<#{Types.yard_type(items["items"])}>")
      elsif props.size == 1
        key, prop = props.first
        Result.new(kind: :json, unwrap: key, **Types.result_model(prop), yard: Types.yard_type(prop))
      else
        Result.new(kind: :json, **Types.result_model(json), yard: Types.yard_type(json))
      end
    end

    # Points deprecated operations at the same method on the newest version
    # of their resource, when there is one.
    def add_replacements(resources)
      latest = newest_by_name(resources)

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

    def newest_by_name(resources)
      resources.group_by(&:name).transform_values { |rs| rs.max_by(&:version_number) }
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
      unused = @overrides.keys - resources.flat_map { |r| r.operations.map(&:operation_id) }
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
