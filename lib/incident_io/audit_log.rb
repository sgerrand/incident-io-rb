# frozen_string_literal: true

module IncidentIo
  # Parses incident.io audit log entries, e.g. from a SIEM log stream or an
  # S3 export. Audit logs are not sent as webhooks or through the API.
  #
  #   entry = IncidentIo::AuditLog.parse(line)
  #   entry.action       # => "alert_route.created"
  #   entry.actor.name
  module AuditLog
    module_function

    # Turns an audit log entry into its model
    #
    # Entry types this gem doesn't know yet come back as the parsed Hash.
    #
    # @param entry [String, Hash] the entry as JSON or already parsed
    # @return [Object, Hash] the model for the entry's action and version
    def parse(entry)
      data = entry.is_a?(String) ? JSON.parse(entry) : entry
      model = ENTRIES[[data["action"], data["version"]]]
      model ? Models.const_get(model).from_api(data) : data
    end
  end
end
