# frozen_string_literal: true

module IncidentIoGenerator
  # Maps OpenAPI schemas to Ruby source for IncidentIo::Model types and to
  # YARD type names for docs.
  module Types
    module_function

    def ref_name(schema)
      schema["$ref"]&.split("/")&.last
    end

    # The values a schema is limited to, or nil when it takes any value.
    # For an array, the values of its items; for a map, the values of its
    # values. These can be nested, like a map of arrays.
    def allowed_values(schema)
      # `additionalProperties` can be true or false as well as a schema.
      return nil unless schema.is_a?(Hash)

      schema["enum"] || allowed_values(schema["items"]) || allowed_values(schema["additionalProperties"])
    end

    # Every limit in a schema, keyed by name: its own allowed values under
    # the given name, and those of the keys of an inline object under names
    # like "name.key". The inline object can sit inside arrays and maps.
    def limits(schema, name)
      own = {name => allowed_values(schema)}.compact
      inline_properties(schema).reduce(own) { |all, (key, prop)| all.merge(limits(prop, "#{name}.#{key}")) }
    end

    # The keys of an inline object and their schemas. For an array or a
    # map, those of the objects it holds, however deep they are nested.
    def inline_properties(schema)
      # `additionalProperties` can be true or false as well as a schema.
      return {} unless schema.is_a?(Hash)

      schema["properties"] || inline_properties(schema["items"]).merge(inline_properties(schema["additionalProperties"]))
    end

    # The operators a filter argument's description names, or nil when it
    # names none. The spec has them only in text like "The accepted
    # operators are 'one_of', or 'not_in'."
    def operators(description)
      description.to_s[/accepted operators? (?:is|are)[^.]*/i]&.scan(/'(\w+)/)&.flatten
    end

    # Ruby source for a field type in `Model.define`. Model references are
    # lazy (`-> { IncidentV2 }`) so models can refer to each other in any
    # order. Written to run inside `IncidentIo::Models`.
    def model_type(schema)
      if (ref = ref_name(schema))
        return "-> { #{ref} }"
      end

      case schema["type"]
      when "string" then string_type(schema)
      when "integer" then ":integer"
      when "number" then ":float"
      when "boolean" then ":boolean"
      when "array" then "[#{model_type(schema["items"] || {})}]"
      when "object" then map_type(schema)
      else ":any"
      end
    end

    # The model a resource call builds its result with, as Result fields:
    # the schema name and how many arrays it is nested in. Empty when the raw
    # value should be returned.
    def result_model(schema)
      return {} if schema.nil?

      if (ref = ref_name(schema))
        {model_name: ref, depth: 0}
      elsif schema["type"] == "array"
        inner = result_model(schema["items"])
        inner.empty? ? {} : inner.merge(depth: inner[:depth] + 1)
      else
        {}
      end
    end

    # YARD type, e.g. "Models::IncidentV2", "Array<String>", "Time". With
    # accepts_hash: true, model types also allow a plain Hash, as request
    # arguments do.
    def yard_type(schema, namespace: "Models::", accepts_hash: false)
      if (ref = ref_name(schema))
        return accepts_hash ? "#{namespace}#{ref}, Hash" : "#{namespace}#{ref}"
      end

      case schema["type"]
      when "string"
        {"date-time" => "Time", "date" => "Date"}.fetch(schema["format"], "String")
      when "integer" then "Integer"
      when "number" then "Float"
      when "boolean" then "Boolean"
      when "array" then "Array<#{yard_type(schema["items"] || {}, namespace:, accepts_hash:)}>"
      when "object"
        extra = schema["additionalProperties"]
        (extra.is_a?(Hash) && !extra.empty?) ? "Hash{String => #{yard_type(extra, namespace:)}}" : "Hash"
      else "Object"
      end
    end

    # RBS type for a schema. With input: true, the type accepted as a method
    # argument: models also take a Hash, times and dates also take a String
    # and objects take any Hash.
    def rbs_type(schema, namespace: "Models::", input: false)
      if (ref = ref_name(schema))
        return input ? "#{namespace}#{ref} | Hash[untyped, untyped]" : "#{namespace}#{ref}"
      end

      case schema["type"]
      when "string"
        case schema["format"]
        when "date-time" then input ? "Time | String" : "Time"
        when "date" then input ? "Date | String" : "Date"
        else "String"
        end
      when "integer" then "Integer"
      when "number" then input ? "Numeric" : "Float"
      when "boolean" then "bool"
      when "array" then "Array[#{rbs_type(schema["items"] || {}, namespace:, input:)}]"
      when "object"
        extra = schema["additionalProperties"]
        if input then "Hash[untyped, untyped]"
        elsif extra.is_a?(Hash) && !extra.empty? then "Hash[String, #{rbs_type(extra, namespace:)}]"
        else "Hash[String, untyped]"
        end
      else "untyped"
      end
    end

    # Makes an RBS type nilable: "String" => "String?", "A | B" => "(A | B)?".
    def rbs_optional(type)
      return type if type == "untyped"

      top_level_union?(type) ? "(#{type})?" : "#{type}?"
    end

    # True for "A | B" but not "Array[A | B]".
    def top_level_union?(type)
      depth = 0
      type.each_char.with_index do |char, i|
        depth += 1 if char == "["
        depth -= 1 if char == "]"
        return true if depth.zero? && type[i, 3] == " | "
      end
      false
    end

    # A JSON value that fits the schema, for tests. Models are passed as
    # plain hashes, which generated methods accept.
    def sample_value(schema, name)
      return {} if ref_name(schema)

      case schema["type"]
      when "string"
        case schema["format"]
        when "date-time" then "2024-01-01T00:00:00Z"
        when "date" then "2024-01-01"
        else schema["enum"]&.first || "#{name}-value"
        end
      when "integer" then 1
      when "number" then 1.5
      when "boolean" then true
      when "array" then [sample_value(schema["items"] || {}, name)]
      when "object" then {"one_of" => ["#{name}-value"]}
      else "#{name}-value"
      end
    end

    def string_type(schema)
      case schema["format"]
      when "date-time" then ":time"
      when "date" then ":date"
      else ":string"
      end
    end

    def map_type(schema)
      extra = schema["additionalProperties"]
      return ":any" unless extra.is_a?(Hash) && !extra.empty?

      "Model.map_of(#{model_type(extra)})"
    end
  end
end
