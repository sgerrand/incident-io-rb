# frozen_string_literal: true

module IncidentIoGenerator
  # Finds webhook event and audit log entry types that a newer copy of the
  # generated code no longer has. Removing a type can break code that uses
  # the gem, so the update workflow lists them in its pull request.
  module RemovedTypes
    # The generated files that map each type to its model, and what each
    # one holds.
    FILES = {
      "lib/incident_io/webhook_events.rb" => "Webhook event",
      "lib/incident_io/audit_log_entries.rb" => "Audit log entry"
    }.freeze
    # A line of a generated map, like
    # `"schedule.deleted_v1" => :ScheduleSlimV2,` or
    # `["alert_route.created", 1] => :AuditLogsAlertRouteCreatedV1,`.
    ENTRY = /^\s+(?:"([^"]+)"|\["([^"]+)", (\d+)\]) => :\w+,?$/

    module_function

    # The types in the source of a generated map, e.g. "`schedule.deleted_v1`"
    # or "`alert_route.created` (version 1)".
    def types(source)
      source.scan(ENTRY).map { |type, action, version| type ? "`#{type}`" : "`#{action}` (version #{version})" }
    end

    # A Markdown section listing the types that are in `before` but not in
    # `after`, or an empty string when there are none. Both hold the source
    # of each file in FILES, keyed by path.
    def report(before, after)
      removed = FILES.flat_map do |path, label|
        (types(before.fetch(path, "")) - types(after.fetch(path, ""))).map { |type| "- #{label} #{type}" }
      end
      return "" if removed.empty?

      <<~MARKDOWN
        ## Removed types

        The latest spec no longer has these types. The gem will stop building models for them, which can break code that uses it.

        #{removed.join("\n")}
      MARKDOWN
    end
  end
end
