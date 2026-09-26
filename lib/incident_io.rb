# frozen_string_literal: true

require "date"
require "json"
require "time"
require "uri"

require_relative "incident_io/version"
require_relative "incident_io/errors"
require_relative "incident_io/util"
require_relative "incident_io/query_encoder"
require_relative "incident_io/response"
require_relative "incident_io/transport/net_http"
require_relative "incident_io/model"
require_relative "incident_io/pager"
require_relative "incident_io/client"
require_relative "incident_io/resource"

# Ruby client for the incident.io API.
module IncidentIo
end
