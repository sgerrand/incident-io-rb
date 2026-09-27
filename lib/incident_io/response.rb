# frozen_string_literal: true

module IncidentIo
  # A raw HTTP response. Header names are lower case.
  Response = Data.define(:status, :headers, :body)

  class Response
    # Whether the status is 2xx
    #
    # @return [Boolean]
    def success?
      (200..299).cover?(status)
    end

    # Whether the body is JSON, going by its Content-Type
    #
    # @return [Boolean]
    def json?
      headers["content-type"].to_s.include?("json")
    end

    # The body, parsed if it's JSON
    #
    # A JSON body that can't be parsed is returned as text.
    #
    # @return [Hash, Array, String, nil] parsed JSON, other text (e.g. CSV),
    #   or nil for an empty body
    def parsed
      text = body
      return nil if text.nil? || text.empty?
      return text unless json?

      JSON.parse(text)
    rescue JSON::ParserError
      text
    end
  end
end
