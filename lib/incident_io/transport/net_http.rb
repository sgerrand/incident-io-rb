# frozen_string_literal: true

require "net/http"
require "openssl"

module IncidentIo
  module Transport
    # Default transport, built on Net::HTTP from the standard library.
    #
    # Any object with the same `call` signature that returns an
    # IncidentIo::Response can be passed to Client.new as `transport:`.
    # It must raise APITimeoutError or APIConnectionError for network
    # failures so the client can retry them.
    class NetHTTP
      TIMEOUT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout].freeze
      CONNECTION_ERRORS = [
        SocketError, SystemCallError, IOError, EOFError,
        OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      ].freeze

      def call(method:, url:, headers:, body:, timeout:, open_timeout:)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = open_timeout
        http.read_timeout = timeout
        http.write_timeout = timeout

        request = Net::HTTPGenericRequest.new(method.to_s.upcase, !body.nil?, true, uri.request_uri, headers)
        request.body = body unless body.nil?

        response = http.request(request)
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
