# frozen_string_literal: true

module IncidentIo
  # Builds query strings the API understands.
  #
  # Hashes use OpenAPI `deepObject` style and arrays repeat the key:
  #
  #   encode(status: { one_of: ["a", "b"] }, page_size: 50)
  #   # => "status%5Bone_of%5D=a&status%5Bone_of%5D=b&page_size=50"
  #
  # Nested hashes nest further, e.g. `custom_field[<id>][one_of]=x`.
  # nil values are left out.
  module QueryEncoder
    module_function

    def encode(params)
      pairs = [] #: Array[[String, String]]
      (params || {}).each { |key, value| append(pairs, key.to_s, value) }
      URI.encode_www_form(pairs)
    end

    def append(pairs, key, value)
      case value
      when nil then nil
      when Hash then value.each { |k, v| append(pairs, "#{key}[#{k}]", v) }
      when Array then value.flatten.each { |v| append(pairs, key, v) }
      else pairs << [key, scalar(value)]
      end
    end
    private_class_method :append

    def scalar(value)
      case value
      when Time then value.utc.iso8601
      when DateTime then value.to_time.utc.iso8601
      when Date then value.iso8601
      else value.to_s
      end
    end
    private_class_method :scalar
  end
end
