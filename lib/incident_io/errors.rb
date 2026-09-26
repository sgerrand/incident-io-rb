# frozen_string_literal: true

module IncidentIo
  # Base class for every error raised by this gem.
  class Error < StandardError; end

  # The client was set up wrongly, e.g. no API key.
  class ConfigurationError < Error; end

  # The request never got a response: DNS, TLS, refused or dropped connection.
  class APIConnectionError < Error; end

  # The request timed out while connecting, sending or reading.
  class APITimeoutError < APIConnectionError; end

  # The API answered with a non-2xx status. Fields come from the API's
  # `ErrorResponse` body when there is one.
  class APIError < Error
    # One entry from `ErrorResponse.errors`.
    Detail = Data.define(:code, :message, :field, :pointer, :metadata)

    # `ErrorResponse.rate_limit`. `retry_after` is a Time.
    RateLimit = Data.define(:name, :limit, :remaining, :retry_after)

    attr_reader :status, :type, :request_id, :errors, :rate_limit, :headers, :body

    def self.from_response(response)
      klass =
        case response.status
        when 400 then BadRequestError
        when 401 then AuthenticationError
        when 403 then PermissionDeniedError
        when 404 then NotFoundError
        when 408 then RequestTimeoutError
        when 409 then ConflictError
        when 422 then UnprocessableEntityError
        when 429 then RateLimitError
        when 500.. then InternalServerError
        else APIError
        end

      klass.new(status: response.status, headers: response.headers, body: response.parsed)
    end

    def initialize(status:, headers: nil, body: nil)
      @status = status
      @headers = headers || {}
      @body = body

      data = body.is_a?(Hash) ? body : {} #: Hash[String, untyped]
      @type = data["type"]
      @request_id = data["request_id"]
      @errors = Array(data["errors"]).map { |e| build_detail(e) }
      @rate_limit = build_rate_limit(data["rate_limit"])

      super(build_message)
    end

    # Seconds the API asked us to wait before retrying, or nil.
    def retry_after
      header = headers["retry-after"]
      if header
        seconds = Float(header, exception: false)
        return seconds if seconds

        at = Util.parse_time(header, httpdate: true)
        return [at - Time.now, 0.0].max if at
      end

      at = rate_limit&.retry_after
      return nil unless at

      [at - Time.now, 0.0].max
    end

    private

    def build_detail(error)
      source = error["source"] || {}
      Detail.new(
        code: error["code"],
        message: error["message"],
        field: source["field"],
        pointer: source["pointer"],
        metadata: error["metadata"]
      )
    end

    def build_rate_limit(data)
      return nil unless data.is_a?(Hash)

      RateLimit.new(
        name: data["name"],
        limit: data["limit"],
        remaining: data["remaining"],
        retry_after: Util.parse_time(data["retry_after"])
      )
    end

    def build_message
      parts = ["#{status}#{" #{type}" if type}"]
      detail = errors.map(&:message).compact.join("; ")
      parts << detail unless detail.empty?
      message = parts.join(": ")
      request_id ? "#{message} (request_id: #{request_id})" : message
    end
  end

  class BadRequestError < APIError; end
  class AuthenticationError < APIError; end
  class PermissionDeniedError < APIError; end
  class NotFoundError < APIError; end
  class RequestTimeoutError < APIError; end
  class ConflictError < APIError; end
  class UnprocessableEntityError < APIError; end
  class RateLimitError < APIError; end
  class InternalServerError < APIError; end
end
