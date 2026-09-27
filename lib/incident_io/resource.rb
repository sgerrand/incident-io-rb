# frozen_string_literal: true

module IncidentIo
  # Base class for API resources. Generated resources subclass this and
  # call the private helpers below:
  #
  #   class Incidents < IncidentIo::Resource
  #     def show(id, request_options: {})
  #       request(:get, path("/v2/incidents/%s", id),
  #               unwrap: "incident", model: Models::IncidentV2, request_options:)
  #     end
  #   end
  class Resource
    DEPRECATION_WARNINGS = Set.new
    DEPRECATION_MUTEX = Mutex.new
    private_constant :DEPRECATION_WARNINGS, :DEPRECATION_MUTEX

    # Whether this is the first deprecation warning for a name
    #
    # @param name [String]
    # @return [Boolean] true the first time for each name, then false
    def self.first_deprecation_warning?(name)
      DEPRECATION_MUTEX.synchronize { !DEPRECATION_WARNINGS.add?(name).nil? }
    end

    # The client that sends this resource's requests
    #
    # @return [Client]
    attr_reader :client

    # Creates a resource that sends requests with the client
    #
    # @param client [Client]
    def initialize(client)
      @client = client
    end

    # A short description that leaves out the client
    #
    # @return [String]
    def inspect
      "#<#{self.class.name}>"
    end

    private

    # Sends a request and builds the result
    #
    # @param method [Symbol]
    # @param path [String]
    # @param unwrap [String, nil] return this key of the response body
    # @param model [Object, nil] any Model type, e.g. `Models::IncidentV2` or
    #   `[Models::SeverityV1]`, to build from the (unwrapped) body
    # @param options [Hash] passed on to Client#request
    # @return [Object]
    def request(method, path, unwrap: nil, model: nil, **options)
      data = client.request(method, path, **options)
      data = data[unwrap] if unwrap && data.is_a?(Hash)
      model ? Model.coerce(model, data) : data
    end

    # Pages through a list endpoint
    #
    # @param path [String]
    # @param items_key [String]
    # @param options [Hash] passed on to Client#paginate
    # @return [Pager]
    def paginate(path, items_key:, **options)
      client.paginate(path, items_key:, **options)
    end

    # Warns once per process that an endpoint is deprecated
    #
    # Shown only when deprecation warnings are on, e.g.
    # `Warning[:deprecated] = true` or `ruby -W:deprecated`.
    #
    # @param name [String] how the endpoint is called
    # @param replacement [String, nil] what to call instead
    # @return [void]
    def deprecated!(name, replacement = nil)
      return unless Warning[:deprecated]
      return unless Resource.first_deprecation_warning?(name)

      message = "#{name} is deprecated by incident.io"
      message += "; use #{replacement} instead" if replacement
      warn(message, category: :deprecated, uplevel: 2)
    end

    # Drops arguments that weren't passed, keeping nil so it's sent as null
    #
    # @param fields [Hash{Symbol => Object}]
    # @return [Hash{Symbol => Object}]
    def given(fields)
      fields.reject { |_, value| NOT_GIVEN.equal?(value) }
    end

    # Fills `%s` placeholders in a path template with escaped IDs
    #
    # @param template [String]
    # @param ids [Array<#to_s>]
    # @return [String]
    def path(template, *ids)
      format(template, *ids.map { |id| Util.escape_path(id) })
    end
  end
end
