# frozen_string_literal: true

module IncidentIoGenerator
  # Maps OpenAPI schemas to Ruby source for IncidentIo::Model types and to
  # YARD type names for docs.
  module Types
    module_function

    def ref_name(schema)
      schema["$ref"]&.split("/")&.last
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

    # Ruby source for the `model:` argument of a resource call, or nil when
    # the raw value should be returned. Written to run inside a resource.
    def result_type(schema)
      return nil if schema.nil?

      if (ref = ref_name(schema))
        "Models::#{ref}"
      elsif schema["type"] == "array" && (inner = result_type(schema["items"]))
        "[#{inner}]"
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
        { "date-time" => "Time", "date" => "Date" }.fetch(schema["format"], "String")
      when "integer" then "Integer"
      when "number" then "Float"
      when "boolean" then "Boolean"
      when "array" then "Array<#{yard_type(schema["items"] || {}, namespace:, accepts_hash:)}>"
      when "object"
        extra = schema["additionalProperties"]
        extra.is_a?(Hash) && !extra.empty? ? "Hash{String => #{yard_type(extra, namespace:)}}" : "Hash"
      else "Object"
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
