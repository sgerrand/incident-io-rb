# frozen_string_literal: true

module IncidentIo
  # One HTTP request, as handed to a transport. Times are in seconds.
  Request = Data.define(:method, :url, :headers, :body, :timeout, :open_timeout)
end
