# frozen_string_literal: true

module IncidentIo
  # A raw HTTP response. Header names are lower case.
  Response = Data.define(:status, :headers, :body)

  class Response
    def success?
      (200..299).cover?(status)
    end

    def json?
      headers["content-type"].to_s.include?("json")
    end

    # The body as a Hash/Array for JSON, a String otherwise (e.g. CSV), or
    # nil when empty.
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
