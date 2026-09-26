# frozen_string_literal: true

module IncidentIo
  # Low-level API client. Handles auth, JSON, errors and retries.
  #
  #   client = IncidentIo::Client.new(api_key: ENV["INCIDENT_IO_API_KEY"])
  #   client.request(:get, "/v2/incidents/#{id}")
  #   client.paginate("/v2/incidents", items_key: "incidents").first(10)
  class Client
    DEFAULT_BASE_URL = "https://api.incident.io"
    DEFAULT_TIMEOUT = 60
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_MAX_RETRIES = 2

    # Safe to repeat: the server treats a repeated call the same as one.
    IDEMPOTENT_METHODS = %i[get head put delete options].freeze
    # Retried only when the request is idempotent.
    RETRYABLE_STATUSES = [408, 500, 502, 503, 504].freeze
    # 429 means the request was not processed, so it is always retried.
    RATE_LIMIT_STATUS = 429

    INITIAL_RETRY_DELAY = 0.5
    MAX_RETRY_DELAY = 8.0
    # If the API asks us to wait longer than this, raise instead.
    MAX_RETRY_AFTER = 60.0

    REQUEST_OPTIONS = %i[api_key timeout open_timeout max_retries headers].freeze

    attr_reader :base_url, :timeout, :open_timeout, :max_retries, :logger

    # @param api_key [String] defaults to ENV["INCIDENT_IO_API_KEY"]
    # @param base_url [String] defaults to ENV["INCIDENT_IO_BASE_URL"] or the public API
    # @param timeout [Numeric] seconds to wait for a response
    # @param open_timeout [Numeric] seconds to wait for a connection
    # @param max_retries [Integer] retries after the first attempt
    # @param logger [Logger, nil] gets one debug line per attempt
    # @param user_agent [String, nil] added before the gem's own user agent
    # @param transport [#call] see Transport::NetHTTP
    def initialize(
      api_key: ENV.fetch("INCIDENT_IO_API_KEY", nil),
      base_url: ENV.fetch("INCIDENT_IO_BASE_URL", DEFAULT_BASE_URL),
      timeout: DEFAULT_TIMEOUT,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      max_retries: DEFAULT_MAX_RETRIES,
      logger: nil,
      user_agent: nil,
      transport: Transport::NetHTTP.new
    )
      if api_key.nil? || api_key.to_s.empty?
        raise ConfigurationError, "no API key: pass api_key: or set INCIDENT_IO_API_KEY"
      end

      @api_key = api_key.to_s
      @base_url = base_url.to_s.chomp("/")
      @timeout = timeout
      @open_timeout = open_timeout
      @max_retries = max_retries
      @logger = logger
      @user_agent = [user_agent, "incident-io-ruby/#{VERSION} ruby/#{RUBY_VERSION}"].compact.join(" ")
      @transport = transport
    end

    # Sends a request and returns the parsed body: a Hash for JSON, a String
    # for other content types (e.g. CSV) and nil for an empty body.
    #
    # @param idempotent [Boolean, nil] whether 5xx and network errors may be
    #   retried. Defaults to true for GET/HEAD/PUT/DELETE. Set true for a POST
    #   that sends an `idempotency_key`.
    # @param request_options [Hash] per-call overrides: api_key, timeout,
    #   open_timeout, max_retries, headers
    # @raise [APIError] for non-2xx responses
    # @raise [APIConnectionError] when no response arrived
    def request(method, path, query: nil, body: nil, idempotent: nil, request_options: {})
      execute(method, path, query:, body:, idempotent:, request_options:).parsed
    end

    # Same as #request but returns the raw Response.
    def execute(method, path, query: nil, body: nil, idempotent: nil, request_options: {})
      method = method.to_s.downcase.to_sym
      options = normalize_options(request_options)
      idempotent = IDEMPOTENT_METHODS.include?(method) if idempotent.nil?
      max_retries = options.fetch(:max_retries, @max_retries)

      call = {
        method:,
        url: build_url(path, query),
        headers: build_headers(options, json_body: !body.nil?),
        body: body.nil? ? nil : JSON.generate(Util.serialize(body)),
        timeout: options.fetch(:timeout, @timeout),
        open_timeout: options.fetch(:open_timeout, @open_timeout)
      }

      with_retries(call, idempotent:, max_retries:)
    end

    # Returns a lazy Pager over every item of a cursor-paginated list.
    #
    # @param items_key [String] key of the item array in the response,
    #   e.g. "incidents"
    # @param model [#from_api, nil] builds each item; raw hashes when nil
    def paginate(path, items_key:, query: {}, model: nil, request_options: {})
      Pager.new(self, path, items_key:, query:, model:, request_options:)
    end

    def inspect
      "#<#{self.class.name} base_url=#{base_url.inspect}>"
    end

    private

    def with_retries(call, idempotent:, max_retries:)
      attempt = 0
      loop do
        response = perform(call, attempt)
        return response if response.success?

        error = APIError.from_response(response)
        delay = retry_delay(error, attempt, idempotent:, max_retries:)
        raise error unless delay

        log { "retrying #{call[:method].upcase} after #{response.status} in #{delay.round(2)}s" }
        sleep_for(delay)
        attempt += 1
      rescue APIConnectionError => e
        raise e unless idempotent && attempt < max_retries

        delay = backoff(attempt)
        log { "retrying #{call[:method].upcase} after #{e.class} in #{delay.round(2)}s" }
        sleep_for(delay)
        attempt += 1
      end
    end

    def perform(call, attempt)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = @transport.call(**call)
      log do
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        "#{call[:method].upcase} #{redact(call[:url])} -> #{response.status} " \
          "(#{(elapsed * 1000).round}ms, attempt #{attempt + 1})"
      end
      response
    end

    # Seconds to wait before the next attempt, or nil to give up.
    def retry_delay(error, attempt, idempotent:, max_retries:)
      return nil if attempt >= max_retries

      if error.status == RATE_LIMIT_STATUS
        wait = error.retry_after
        return backoff(attempt) if wait.nil?
        return nil if wait > MAX_RETRY_AFTER

        return wait
      end

      return nil unless idempotent && RETRYABLE_STATUSES.include?(error.status)

      wait = error.retry_after
      wait && wait <= MAX_RETRY_AFTER ? wait : backoff(attempt)
    end

    # Exponential backoff with up to 25% jitter: ~0.5s, 1s, 2s ... 8s.
    def backoff(attempt)
      delay = [INITIAL_RETRY_DELAY * (2**attempt), MAX_RETRY_DELAY].min
      delay * (1 - (rand * 0.25))
    end

    def sleep_for(seconds)
      sleep(seconds)
    end

    def build_url(path, query)
      path = "/#{path}" unless path.start_with?("/")
      encoded = QueryEncoder.encode(query)
      encoded.empty? ? "#{base_url}#{path}" : "#{base_url}#{path}?#{encoded}"
    end

    def build_headers(options, json_body:)
      headers = {
        "Authorization" => "Bearer #{options.fetch(:api_key, @api_key)}",
        "Accept" => "application/json",
        "User-Agent" => @user_agent
      }
      headers["Content-Type"] = "application/json" if json_body
      headers.merge(options.fetch(:headers, {}))
    end

    def normalize_options(options)
      options = (options || {}).transform_keys(&:to_sym)
      unknown = options.keys - REQUEST_OPTIONS
      raise ArgumentError, "unknown request option#{"s" if unknown.size > 1}: #{unknown.join(", ")}" if unknown.any?

      options
    end

    # Some endpoints take a secret `token` in the query string.
    def redact(url)
      url.gsub(/([?&]token=)[^&]*/, '\1[REDACTED]')
    end

    def log(&)
      logger&.debug { "[incident-io] #{yield}" }
    end
  end
end
