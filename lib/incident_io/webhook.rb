# frozen_string_literal: true

require "openssl"

module IncidentIo
  # Checks and parses incident.io webhooks. incident.io sends them through
  # Svix, which signs each one with the endpoint's signing secret.
  #
  #   # In a Rails controller:
  #   event = IncidentIo::Webhook.construct_event(
  #     request.raw_post, request.headers, secret: ENV["INCIDENT_IO_WEBHOOK_SECRET"]
  #   )
  #
  #   case event.type
  #   when "public_incident.incident_created_v2"
  #     event.data.name
  #   end
  #
  # Private events only carry the ID of what changed. Fetch the rest with the
  # API, e.g. `client.incidents.show(event.data.id)`.
  module Webhook
    # Reject webhooks sent more than this many seconds before or after now.
    DEFAULT_TOLERANCE = 5 * 60
    SIGNATURE_VERSION = "v1"
    SECRET_PREFIX = "whsec_"

    # The webhook's signature or timestamp is missing, wrong or too old.
    class SignatureError < Error; end

    # A parsed webhook.
    #   id: the webhook-id header, the same across retries, or nil
    #   type: the event type, e.g. "public_incident.incident_created_v2"
    #   data: the payload model, or the raw payload for unknown event types
    #   raw: the whole parsed body
    Event = Data.define(:id, :type, :data, :raw)

    module_function

    # Checks the signature, then parses the webhook
    #
    # @param payload [String] the raw request body, exactly as received
    # @param headers [#each] request headers: a Hash, Rails' request.headers or
    #   a Rack env
    # @param secret [String] the endpoint's signing secret, "whsec_..."
    # @param tolerance [Integer] seconds a webhook may be early or late
    # @param now [Time] the time to check against
    # @raise [SignatureError] when the webhook can't be trusted
    # @return [Event]
    def construct_event(payload, headers, secret:, tolerance: DEFAULT_TOLERANCE, now: Time.now)
      verify!(payload, headers, secret:, tolerance:, now:)
      parse(payload, id: find_header(headers, "id"))
    end

    # Checks that the webhook was signed with the secret and sent in time
    #
    # @param payload [String] the raw request body, exactly as received
    # @param headers [#each] request headers
    # @param secret [String] the endpoint's signing secret, "whsec_..."
    # @param tolerance [Integer] seconds a webhook may be early or late
    # @param now [Time] the time to check against
    # @raise [SignatureError] when the webhook can't be trusted
    # @return [true]
    def verify!(payload, headers, secret:, tolerance: DEFAULT_TOLERANCE, now: Time.now)
      id = find_header(headers, "id")
      timestamp = find_header(headers, "timestamp")
      signatures = find_header(headers, "signature")
      unless id && timestamp && signatures
        raise SignatureError, "missing webhook-id, webhook-timestamp or webhook-signature header"
      end

      sent_at = Integer(timestamp, exception: false)
      raise SignatureError, "invalid webhook-timestamp header" unless sent_at
      raise SignatureError, "webhook timestamp is outside the tolerance" if (now.to_i - sent_at).abs > tolerance

      expected = sign(payload, id:, timestamp: sent_at, secret:)
      # The header can hold several space-separated "version,signature" pairs,
      # e.g. while the secret is being rotated.
      matched = signatures.split(" ").any? do |pair|
        version, signature = pair.split(",", 2)
        version == SIGNATURE_VERSION && !signature.nil? && OpenSSL.secure_compare(signature, expected)
      end
      raise SignatureError, "no signature matches" unless matched

      true
    end

    # The base64 HMAC-SHA256 signature of a webhook, as Svix computes it
    #
    # @param payload [String]
    # @param id [String] the webhook-id header
    # @param timestamp [Integer] the webhook-timestamp header
    # @param secret [String] the endpoint's signing secret
    # @return [String]
    def sign(payload, id:, timestamp:, secret:)
      key = decode_secret(secret)
      [OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.#{payload}")].pack("m0")
    end

    # Parses a webhook body without checking its signature
    #
    # Only use this for payloads you already trust.
    #
    # @param payload [String, Hash] the body as JSON or already parsed
    # @param id [String, nil] the webhook-id header, if known
    # @return [Event]
    def parse(payload, id: nil)
      raw = payload.is_a?(String) ? JSON.parse(payload) : payload
      type = raw["event_type"]
      model = EVENTS[type]
      data = raw[type]
      Event.new(id:, type:, data: model ? Models.const_get(model).from_api(data) : data, raw:)
    end

    # Finds a webhook header, e.g. "id" finds "webhook-id"
    #
    # Also accepts Svix's older "svix-" names and Rack env keys like
    # "HTTP_WEBHOOK_ID".
    #
    # @param headers [#each]
    # @param name [String]
    # @return [String, nil]
    def find_header(headers, name)
      wanted = ["webhook-#{name}", "svix-#{name}"]
      headers.each do |key, value|
        normalized = key.to_s.downcase.delete_prefix("http_").tr("_", "-")
        return value.to_s if wanted.include?(normalized)
      end
      nil
    end

    # The key bytes from a signing secret
    #
    # @param secret [String] "whsec_" and base64, or just base64
    # @raise [ConfigurationError] when the secret isn't valid base64
    # @return [String]
    def decode_secret(secret)
      secret.delete_prefix(SECRET_PREFIX).unpack1("m0") #: String
    rescue ArgumentError
      raise ConfigurationError, "webhook secret is not valid base64"
    end
  end
end
