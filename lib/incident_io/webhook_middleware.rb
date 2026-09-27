# frozen_string_literal: true

module IncidentIo
  module Webhook
    # Rack middleware that checks and parses incident.io webhooks.
    #
    # With a block, it handles webhooks itself and replies 204:
    #
    #   use IncidentIo::Webhook::Middleware, secret: ENV["INCIDENT_IO_WEBHOOK_SECRET"] do |event|
    #     IncidentJob.perform_later(event.raw) if event.type == "public_incident.incident_created_v2"
    #   end
    #
    # Without one, it stores the event in the Rack env under ENV_KEY and
    # passes the request on, e.g. to a Rails route:
    #
    #   config.middleware.use IncidentIo::Webhook::Middleware, secret: ENV["INCIDENT_IO_WEBHOOK_SECRET"]
    #   # then, in a controller: request.env[IncidentIo::Webhook::Middleware::ENV_KEY]
    #
    # Only POST requests to `path` are checked; everything else passes
    # through untouched. A webhook that fails the check gets a 400 reply.
    # Errors raised by the block propagate, so incident.io retries the webhook.
    class Middleware
      DEFAULT_PATH = "/incident_io/webhooks"
      ENV_KEY = "incident_io.webhook.event"

      # Creates the middleware
      #
      # @param app [#call] the next Rack app
      # @param secret [String] the endpoint's signing secret, "whsec_..."
      # @param path [String] the path incident.io sends webhooks to
      # @param tolerance [Integer] seconds a webhook may be early or late
      # @yieldparam event [Event] a checked, parsed webhook
      def initialize(app, secret:, path: DEFAULT_PATH, tolerance: DEFAULT_TOLERANCE, &handler)
        @app = app
        @secret = secret
        @path = path
        @tolerance = tolerance
        @handler = handler
      end

      # Handles a Rack request
      #
      # @param env [Hash] the Rack env
      # @return [Array(Integer, Hash, Array<String>)] a Rack response
      def call(env)
        return @app.call(env) unless env["REQUEST_METHOD"] == "POST" && env["PATH_INFO"] == @path

        begin
          event = Webhook.construct_event(read_body(env), env, secret: @secret, tolerance: @tolerance)
        rescue SignatureError, JSON::ParserError => e
          return [400, {"content-type" => "text/plain"}, ["Invalid webhook: #{e.message}"]]
        end

        handler = @handler
        return @app.call(env.merge(ENV_KEY => event)) unless handler

        handler.call(event)
        headers = {} #: Hash[String, String]
        body = [] #: Array[String]
        [204, headers, body]
      end

      private

      # The raw request body, leaving the input readable for other code
      #
      # @param env [Hash]
      # @return [String]
      def read_body(env)
        input = env["rack.input"]
        return "" if input.nil?

        input.rewind if input.respond_to?(:rewind)
        body = input.read.to_s
        input.rewind if input.respond_to?(:rewind)
        body
      end
    end
  end
end
