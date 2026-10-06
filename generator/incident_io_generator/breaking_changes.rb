# frozen_string_literal: true

module IncidentIoGenerator
  # Finds changes in a newer copy of the generated code that can break code
  # that uses the gem, so the update workflow can list them in its pull
  # request:
  #
  # - a webhook event type, audit log entry type, model, model field or
  #   resource method that was removed
  # - a model field that changed type
  # - a resource method whose arguments or return type changed
  module BreakingChanges
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
    # The line of a model file that names the model.
    MODEL = /^\s+class (\w+)$/
    # The YARD lines of a model file for one field: its name, its summary
    # and its type, like "Time" or "Array<UserV2>".
    FIELD = /^\s+# @!attribute \[r\] (\S+)\n.*\n\s+#   @return \[(.+), nil\]$/

    # The most changes to list. A pull request body can't hold many more.
    LIMIT = 100

    module_function

    # What the generated code under a root offers.
    def surface(root)
      read = ->(path) { File.read(File.join(root, path)) }
      {
        events: read[EVENTS_PATH].scan(EVENT).flatten,
        entries: read[ENTRIES_PATH].scan(ENTRY).map { |action, version| "`#{action}` (version #{version})" },
        # Each model's fields and their types, keyed by the model's name.
        models: Dir.glob("#{MODELS_PATH}/*.rb", base: root).sort.to_h do |path|
          source = read[path]
          [source[MODEL, 1], source.scan(FIELD).to_h]
        end,
        # How each method is called, keyed by the call.
        methods: JSON.parse(read[OPERATIONS_PATH]).to_h do |op|
          ["client.#{op["version"]}.#{op["resource"]}.#{op["method"]}", signature(op)]
        end
      }
    end

    # A method's arguments, their types and what it returns, from its entry
    # in the operations manifest.
    def signature(op)
      types = op.fetch("arg_types")
      positional = op.fetch("path_args").map { |arg| arg.delete_suffix("-value") }
      required = op.fetch("keyword_args").keys
      {positional:, required:, optional: types.keys - positional - required, types:, returns: op.fetch("returns")}
    end

    # The breaking changes from `before` to `after`, one line each. Both
    # come from #surface.
    def changes(before, after)
      [
        *(before[:events] - after[:events]).map { |type| "Webhook event `#{type}` was removed" },
        *(before[:entries] - after[:entries]).map { |entry| "Audit log entry #{entry} was removed" },
        *(before[:models].keys - after[:models].keys).map { |model| "Model `#{model}` was removed" },
        *field_changes(before[:models], after[:models]),
        *method_changes(before[:methods], after[:methods])
      ]
    end

    # Fields that were removed or changed type, in models that both have.
    # The fields of a removed model aren't listed one by one.
    def field_changes(before, after)
      after.flat_map do |model, fields|
        before.fetch(model, {}).filter_map do |field, type|
          if !fields.key?(field)
            "Field `#{model}##{field}` was removed"
          elsif fields[field] != type
            "Field `#{model}##{field}` changed type from `#{type}` to `#{fields[field]}`"
          end
        end
      end
    end

    # Methods that were removed, and methods that can no longer be used the
    # same way: their positional arguments changed, they lost a keyword
    # argument, they need a new one, an argument changed type or they
    # return something else.
    def method_changes(before, after)
      before.flat_map do |name, was|
        now = after[name]
        next ["Method `#{name}` was removed"] unless now

        positional = [was, now].map { |args| "`(#{args[:positional].join(", ")})`" }
        [
          *("Method `#{name}` changed its positional arguments from #{positional.first} to #{positional.last}" if positional.uniq.size > 1),
          *(was[:required] + was[:optional] - now[:required] - now[:optional]).map { |arg| "Method `#{name}` no longer takes `#{arg}:`" },
          *(now[:required] - was[:required]).map { |arg| "Method `#{name}` now needs `#{arg}:`" },
          *was[:types].filter_map do |arg, type|
            now_type = now[:types].fetch(arg, type)
            "Method `#{name}` changed the type of argument `#{arg}` from `#{type}` to `#{now_type}`" if now_type != type
          end,
          *("Method `#{name}` changed what it returns from `#{was[:returns]}` to `#{now[:returns]}`" if was[:returns] != now[:returns])
        ]
      end
    end

    # A Markdown section listing the breaking changes from the generated
    # code under before_root to the code under after_root, or an empty
    # string when there are none.
    def report(before_root, after_root)
      lines = changes(surface(before_root), surface(after_root))
      return "" if lines.empty?

      shown = lines.first(LIMIT)
      shown << "and #{lines.size - LIMIT} more" if lines.size > LIMIT

      <<~MARKDOWN
        ## Breaking changes

        The latest spec removes or changes these. Each one can break code that uses the gem.

        #{shown.map { |line| "- #{line}" }.join("\n")}
      MARKDOWN
    end
  end
end
