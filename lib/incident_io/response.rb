# frozen_string_literal: true

module IncidentIo
  # A raw HTTP response. Header names are lower case.
  Response = Data.define(:status, :headers, :body) do
    def success?
      (200..299).cover?(status)
    end

    def json?
      headers["content-type"].to_s.include?("json")
    end

    # The body as a Hash/Array for JSON, a String otherwise (e.g. CSV), or
    # nil when empty.
    def parsed
      return nil if body.nil? || body.empty?
      return body unless json?

      JSON.parse(body)
    rescue JSON::ParserError
      body
    end
  end
end
