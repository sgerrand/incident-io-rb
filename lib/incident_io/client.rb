# frozen_string_literal: true

module IncidentIo
  # The API client. Handles auth, JSON, errors and retries.
  #
  #   client = IncidentIo::Client.new(api_key: ENV["INCIDENT_IO_API_KEY"])
  #   client.incidents.show(id)                   # newest version of a resource
  #   client.v1.incidents.list                    # a specific version
  #   client.request(:get, "/v2/incidents/#{id}") # any endpoint, raw
  class Client
    include Resources::Accessors

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

    # The API's address, without a trailing slash
    #
    # @return [String]
    attr_reader :base_url

    # Seconds to wait for a response
    #
    # @return [Integer, Float]
    attr_reader :timeout

    # Seconds to wait for a connection
    #
    # @return [Integer, Float]
    attr_reader :open_timeout

    # How many times to retry after the first attempt
    #
    # @return [Integer]
    attr_reader :max_retries

    # Gets one debug line per attempt
    #
    # @return [Logger, nil]
    attr_reader :logger

    # Creates a client
    #
    # @param api_key [String] defaults to ENV["INCIDENT_IO_API_KEY"]
    # @param base_url [String] defaults to ENV["INCIDENT_IO_BASE_URL"] or the public API
    # @param timeout [Integer, Float] seconds to wait for a response
    # @param open_timeout [Integer, Float] seconds to wait for a connection
    # @param max_retries [Integer] retries after the first attempt
    # @param logger [Logger, nil] gets one debug line per attempt
    # @param user_agent [String, nil] added before the gem's own user agent
    # @param transport [#call] see Transport::NetHTTP
    # @raise [ConfigurationError] when there's no API key
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

    # Sends a request and returns the parsed body
    #
    # @param method [Symbol, String] the HTTP method, e.g. :get
    # @param path [String] e.g. "/v2/incidents"
    # @param query [Hash, nil] query parameters; nil values are left out
    # @param body [Hash, nil] sent as JSON
    # @param idempotent [Boolean, nil] whether 5xx and network errors may be
    #   retried. Defaults to true for GET/HEAD/PUT/DELETE. Set true for a POST
    #   that sends an `idempotency_key`.
    # @param request_options [Hash] per-call overrides: api_key, timeout,
    #   open_timeout, max_retries, headers
    # @raise [APIError] for non-2xx responses
    # @raise [APIConnectionError] when no response arrived
    # @return [Hash, Array, String, nil] parsed JSON, other text (e.g. CSV),
    #   or nil for an empty body
    def request(method, path, query: nil, body: nil, idempotent: nil, request_options: {})
      execute(method, path, query:, body:, idempotent:, request_options:).parsed
    end

    # Sends a request and returns the raw Response
    #
    # @param method [Symbol, String] the HTTP method, e.g. :get
    # @param path [String] e.g. "/v2/incidents"
    # @param query [Hash, nil] query parameters; nil values are left out
    # @param body [Hash, nil] sent as JSON
    # @param idempotent [Boolean, nil] whether 5xx and network errors may be
    #   retried. Defaults to true for GET/HEAD/PUT/DELETE. Set true for a POST
    #   that sends an `idempotency_key`.
    # @param request_options [Hash] per-call overrides: api_key, timeout,
    #   open_timeout, max_retries, headers
    # @raise [APIError] for non-2xx responses
    # @raise [APIConnectionError] when no response arrived
    # @return [Response]
    def execute(method, path, query: nil, body: nil, idempotent: nil, request_options: {})
      method = method.to_s.downcase.to_sym
      options = normalize_options(request_options)
      idempotent = IDEMPOTENT_METHODS.include?(method) if idempotent.nil?
      max_retries = options.fetch(:max_retries, @max_retries)

      request = Request.new(
        method:,
        url: build_url(path, query),
        headers: build_headers(options, json_body: !body.nil?),
        body: body.nil? ? nil : JSON.generate(Util.serialize(body)),
        timeout: options.fetch(:timeout, @timeout),
        open_timeout: options.fetch(:open_timeout, @open_timeout)
      )

      with_retries(request, idempotent:, max_retries:)
    end

    # A lazy Pager over every item of a cursor-paginated list
    #
    # @param path [String] e.g. "/v2/incidents"
    # @param items_key [String] key of the item array in the response,
    #   e.g. "incidents"
    # @param query [Hash, nil] query parameters; `after` sets the first cursor
    # @param model [#from_api, nil] builds each item; raw hashes when nil
    # @param request_options [Hash] see #request
    # @return [Pager]
    def paginate(path, items_key:, query: nil, model: nil, request_options: {})
      Pager.new(self, path, items_key:, query:, model:, request_options:)
    end

    # A short description that leaves out the API key
    #
    # @return [String]
    def inspect
      "#<#{self.class.name} base_url=#{base_url.inspect}>"
    end

    private

    # Sends a request, retrying when that's safe and useful
    #
    # @param request [Request]
    # @param idempotent [Boolean]
    # @param max_retries [Integer]
    # @raise [APIError, APIConnectionError] once retries run out
    # @return [Response] a 2xx response
    def with_retries(request, idempotent:, max_retries:)
      attempt = 0
      loop do
        begin
          response = perform(request, attempt)
          return response if response.success?

          error = APIError.from_response(response)
          delay = retry_delay(error, attempt, idempotent:, max_retries:)
          reason = response.status
        rescue APIConnectionError => e
          error = e
          delay = (backoff(attempt) if idempotent && attempt < max_retries)
          reason = e.class
        end
        raise error unless delay

        log { "retrying #{request.method.upcase} after #{reason} in #{delay.round(2)}s" }
        sleep(delay)
        attempt += 1
      end
    end

    # Sends one attempt through the transport and logs it
    #
    # @param request [Request]
    # @param attempt [Integer] 0 for the first attempt
    # @return [Response]
    def perform(request, attempt)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = @transport.call(request)
      log do
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        "#{request.method.upcase} #{redact(request.url)} -> #{response.status} " \
          "(#{(elapsed * 1000).round}ms, attempt #{attempt + 1})"
      end
      response
    end

    # How long to wait before the next attempt
    #
    # @param error [APIError]
    # @param attempt [Integer]
    # @param idempotent [Boolean]
    # @param max_retries [Integer]
    # @return [Float, nil] seconds, or nil to give up
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
      (wait && wait <= MAX_RETRY_AFTER) ? wait : backoff(attempt)
    end

    # Exponential backoff with up to 25% jitter: about 0.5s, 1s, 2s … 8s
    #
    # @param attempt [Integer]
    # @return [Float] seconds
    def backoff(attempt)
      delay = [INITIAL_RETRY_DELAY * (2**attempt), MAX_RETRY_DELAY].min
      delay * (1 - (rand * 0.25))
    end

    # The full URL for a path and query
    #
    # @param path [String]
    # @param query [Hash, nil]
    # @return [String]
    def build_url(path, query)
      path = "/#{path}" unless path.start_with?("/")
      encoded = QueryEncoder.encode(query)
      encoded.empty? ? "#{base_url}#{path}" : "#{base_url}#{path}?#{encoded}"
    end

    # The request headers, including auth
    #
    # @param options [Hash] normalized request options
    # @param json_body [Boolean] whether a JSON body is sent
    # @return [Hash{String => String}]
    def build_headers(options, json_body:)
      headers = {
        "Authorization" => "Bearer #{options.fetch(:api_key, @api_key)}",
        "Accept" => "application/json",
        "User-Agent" => @user_agent
      }
      headers["Content-Type"] = "application/json" if json_body
      extra = options[:headers]
      extra ? headers.merge(extra) : headers
    end

    # Request options with symbol keys, checked for typos
    #
    # @param options [Hash, nil]
    # @raise [ArgumentError] for unknown options
    # @return [Hash{Symbol => Object}]
    def normalize_options(options)
      options = (options || {}).transform_keys(&:to_sym)
      unknown = options.keys - REQUEST_OPTIONS
      raise ArgumentError, "unknown request option#{"s" if unknown.size > 1}: #{unknown.join(", ")}" if unknown.any?

      options
    end

    # The URL with any `token` query value hidden, for logs
    #
    # Some endpoints take a secret `token` in the query string.
    #
    # @param url [String]
    # @return [String]
    def redact(url)
      url.gsub(/([?&]token=)[^&]*/, '\1[REDACTED]')
    end

    # Logs a debug line, built only when the logger wants it
    #
    # @yieldreturn [String] the message
    # @return [void]
    def log(&)
      logger&.debug { "[incident-io] #{yield}" }
    end
  end
end
