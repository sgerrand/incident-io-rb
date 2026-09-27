# frozen_string_literal: true

require "net/http"
require "openssl"

module IncidentIo
  module Transport
    # Default transport, built on Net::HTTP from the standard library.
    #
    # Any object with a `call(request)` method that takes an
    # IncidentIo::Request and returns an IncidentIo::Response can be passed
    # to Client.new as `transport:`. It must raise APITimeoutError or
    # APIConnectionError for network failures so the client can retry them.
    class NetHTTP
      TIMEOUT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout].freeze
      CONNECTION_ERRORS = [
        SocketError, SystemCallError, IOError, EOFError,
        OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      ].freeze

      # Sends a request
      #
      # @param request [Request]
      # @raise [APITimeoutError, APIConnectionError] when no response arrives
      # @return [Response]
      def call(request)
        uri = URI(request.url)
        host = uri.hostname
        raise ArgumentError, "not an HTTP URL: #{request.url}" unless uri.is_a?(URI::HTTP) && host

        http = Net::HTTP.new(host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = request.open_timeout
        http.read_timeout = request.timeout
        http.write_timeout = request.timeout

        # e.g. Net::HTTP::Get for :get
        http_request = Net::HTTP.const_get(request.method.to_s.capitalize).new(uri.request_uri, request.headers)
        http_request.body = request.body unless request.body.nil?

        response = http.request(http_request)
        Response.new(
          status: response.code.to_i,
          headers: response.to_hash.transform_values { |values| values.join(", ") },
          body: response.body
        )
      rescue *TIMEOUT_ERRORS => e
        raise APITimeoutError, "request timed out: #{e.message}"
      rescue *CONNECTION_ERRORS => e
        raise APIConnectionError, "connection failed: #{e.class}: #{e.message}"
      end
    end
  end
end
