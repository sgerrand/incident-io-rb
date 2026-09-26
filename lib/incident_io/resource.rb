# frozen_string_literal: true

module IncidentIo
  # Base class for API resources. Generated resources subclass this and
  # call the private helpers below:
  #
  #   class Incidents < IncidentIo::Resource
  #     def show(id, **request_options)
  #       request(:get, path("/v2/incidents/%s", id),
  #               unwrap: "incident", model: IncidentV2, request_options:)
  #     end
  #   end
  class Resource
    attr_reader :client

    def initialize(client)
      @client = client
    end

    def inspect
      "#<#{self.class.name}>"
    end

    private

    # Sends a request. With `unwrap:` returns that key of the response body.
    # With `model:` builds the model from the (unwrapped) body.
    def request(method, path, unwrap: nil, model: nil, **options)
      data = client.request(method, path, **options)
      data = data[unwrap] if unwrap && data.is_a?(Hash)
      model ? model.from_api(data) : data
    end

    def paginate(path, **options)
      client.paginate(path, **options)
    end

    # Fills `%s` placeholders in a path template with escaped IDs.
    def path(template, *ids)
      format(template, *ids.map { |id| Util.escape_path(id) })
    end
  end
end
