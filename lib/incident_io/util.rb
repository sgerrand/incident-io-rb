# frozen_string_literal: true

module IncidentIo
  # Small helpers shared by the client, models and resources.
  module Util
    module_function

    # Turns Ruby values into plain JSON-ready values: string keys, ISO 8601
    # times and models as hashes keyed by their API field names.
    def serialize(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s, serialize(v)] }
      when Array then value.map { |v| serialize(v) }
      when Model::InstanceMethods then value.to_api
      when Data then serialize(value.to_h)
      when Time then value.utc.iso8601(3)
      when DateTime then value.to_time.utc.iso8601(3)
      when Date then value.iso8601
      when Symbol then value.to_s
      else value
      end
    end

    # Escapes one path segment, e.g. an ID, so it can't change the path.
    def escape_path(segment)
      URI.encode_uri_component(segment.to_s)
    end

    # Parses an ISO 8601 (or, with httpdate: true, an HTTP date) string.
    # Returns nil when the value is blank or can't be parsed.
    def parse_time(value, httpdate: false)
      return value if value.is_a?(Time)
      return nil if value.nil? || value.to_s.empty?

      httpdate ? Time.httpdate(value.to_s) : Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
