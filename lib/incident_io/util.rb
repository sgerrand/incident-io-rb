# frozen_string_literal: true

module IncidentIo
  # Small helpers shared by the client, models and resources.
  module Util
    module_function

    # Turns Ruby values into plain values ready for JSON
    #
    # Keys become strings, times become ISO 8601 strings and models become
    # hashes keyed by their API field names.
    #
    # @param value [Object]
    # @return [Object]
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

    # Escapes one path segment, e.g. an ID, so it can't change the path
    #
    # @param segment [#to_s]
    # @return [String]
    def escape_path(segment)
      URI.encode_uri_component(segment.to_s)
    end

    # Parses an ISO 8601 time, or an HTTP date with httpdate: true
    #
    # @param value [String, Time, nil]
    # @param httpdate [Boolean] parse an HTTP date, e.g. from Retry-After
    # @return [Time, nil] nil when the value is blank or can't be parsed
    def parse_time(value, httpdate: false)
      return value if value.is_a?(Time)
      return nil if value.nil? || value.to_s.empty?

      httpdate ? Time.httpdate(value.to_s) : Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
