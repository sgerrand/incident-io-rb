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

    # Returns true the first time it is called for a name, then false.
    def self.first_deprecation_warning?(name)
      DEPRECATION_MUTEX.synchronize { DEPRECATION_WARNINGS.add?(name) ? true : false }
    end

    attr_reader :client

    def initialize(client)
      @client = client
    end

    def inspect
      "#<#{self.class.name}>"
    end

    private

    # Sends a request. With `unwrap:` returns that key of the response body.
    # With `model:` builds the result from the (unwrapped) body. `model:`
    # takes any Model type, e.g. `Models::IncidentV2` or `[Models::SeverityV1]`.
    def request(method, path, unwrap: nil, model: nil, **options)
      data = client.request(method, path, **options)
      data = data[unwrap] if unwrap && data.is_a?(Hash)
      model ? Model.coerce(model, data) : data
    end

    def paginate(path, **options)
      client.paginate(path, **options)
    end

    # Warns once per process that an endpoint is deprecated. Shown only when
    # deprecation warnings are on, e.g. `Warning[:deprecated] = true` or
    # `ruby -W:deprecated`.
    def deprecated!(name, replacement = nil)
      return unless Warning[:deprecated]
      return unless Resource.first_deprecation_warning?(name)

      message = "#{name} is deprecated by incident.io"
      message += "; use #{replacement} instead" if replacement
      warn(message, category: :deprecated, uplevel: 2)
    end

    # Fills `%s` placeholders in a path template with escaped IDs.
    def path(template, *ids)
      format(template, *ids.map { |id| Util.escape_path(id) })
    end
  end
end
