# frozen_string_literal: true

module IncidentIoGenerator
  # Finds what a newer copy of the generated code no longer has: webhook
  # event types, audit log entry types, models, model fields and resource
  # methods. Removing any of these can break code that uses the gem, so the
  # update workflow lists them in its pull request.
  module Removals
    EVENTS_PATH = "lib/incident_io/webhook_events.rb"
    ENTRIES_PATH = "lib/incident_io/audit_log_entries.rb"
    MODELS_PATH = "lib/incident_io/models"
    OPERATIONS_PATH = "spec/fixtures/operations.json"
    # The generated code that is read, relative to the repository root.
    PATHS = [EVENTS_PATH, ENTRIES_PATH, MODELS_PATH, OPERATIONS_PATH].freeze

    # A line of the webhook event map, like
    # `"schedule.deleted_v1" => :ScheduleSlimV2,`.
    EVENT = /^\s+"([^"]+)" => :\w+,?$/
    # A line of the audit log entry map, like
    # `["alert_route.created", 1] => :AuditLogsAlertRouteCreatedV1,`.
    ENTRY = /^\s+\["([^"]+)", (\d+)\] => :\w+,?$/
    # The lines of a model file that name the model and each of its fields.
    MODEL = /^\s+class (\w+)$/
    FIELD = /^\s+# @!attribute \[r\] (\S+)$/

    # The most removals to list. A pull request body can't hold many more.
    LIMIT = 100

    module_function

    # What the generated code under a root offers.
    def surface(root)
      read = ->(path) { File.read(File.join(root, path)) }
      {
        events: read[EVENTS_PATH].scan(EVENT).flatten,
        entries: read[ENTRIES_PATH].scan(ENTRY).map { |action, version| "`#{action}` (version #{version})" },
        # Each model's fields, keyed by the model's name.
        models: Dir.glob("#{MODELS_PATH}/*.rb", base: root).sort.to_h do |path|
          source = read[path]
          [source[MODEL, 1], source.scan(FIELD).flatten]
        end,
        methods: JSON.parse(read[OPERATIONS_PATH]).map { |op| "client.#{op["version"]}.#{op["resource"]}.#{op["method"]}" }
      }
    end

    # What `before` offers that `after` doesn't, one line each. Both come
    # from #surface. The fields of a removed model aren't listed one by one.
    def removed(before, after)
      [
        *(before[:events] - after[:events]).map { |type| "Webhook event `#{type}`" },
        *(before[:entries] - after[:entries]).map { |entry| "Audit log entry #{entry}" },
        *(before[:models].keys - after[:models].keys).map { |model| "Model `#{model}`" },
        *after[:models].flat_map do |model, fields|
          (before[:models].fetch(model, []) - fields).map { |field| "Field `#{model}##{field}`" }
        end,
        *(before[:methods] - after[:methods]).map { |method| "Method `#{method}`" }
      ]
    end

    # A Markdown section listing what the generated code under before_root
    # has that the code under after_root doesn't, or an empty string when
    # nothing was removed.
    def report(before_root, after_root)
      lines = removed(surface(before_root), surface(after_root))
      return "" if lines.empty?

      shown = lines.first(LIMIT)
      shown << "and #{lines.size - LIMIT} more" if lines.size > LIMIT

      <<~MARKDOWN
        ## Removed

        The latest spec no longer has these. Removing them can break code that uses the gem.

        #{shown.map { |line| "- #{line}" }.join("\n")}
      MARKDOWN
    end
  end
end
