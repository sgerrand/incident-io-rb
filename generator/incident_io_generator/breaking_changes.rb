# frozen_string_literal: true

module IncidentIoGenerator
  # Finds changes in a newer copy of the generated code that can break code
  # that uses the gem, so the update workflow can list them in its pull
  # request:
  #
  # - a webhook event type, audit log entry type, model, model field or
  #   resource method that was removed
  # - a model field that changed type or allows other values
  # - a resource method whose arguments or return type changed, or with an
  #   argument that allows fewer values or operators
  module BreakingChanges
    EVENTS_PATH = "lib/incident_io/webhook_events.rb"
    ENTRIES_PATH = "lib/incident_io/audit_log_entries.rb"
    MODELS_PATH = "lib/incident_io/models"
    OPERATIONS_PATH = "spec/fixtures/operations.json"
    VALUES_PATH = "spec/fixtures/allowed_values.json"
    # The generated code that is read, relative to the repository root.
    PATHS = [EVENTS_PATH, ENTRIES_PATH, MODELS_PATH, OPERATIONS_PATH, VALUES_PATH].freeze

    # A line of the webhook event map, like
    # `"schedule.deleted_v1" => :ScheduleSlimV2,`.
    EVENT = /^\s+"([^"]+)" => :\w+,?$/
    # A line of the audit log entry map, like
    # `["alert_route.created", 1] => :AuditLogsAlertRouteCreatedV1,`.
    ENTRY = /^\s+\["([^"]+)", (\d+)\] => :\w+,?$/
    # The model in a line of either map.
    MAPPED = /=> :(\w+)/
    # The line of a model file that names the model.
    MODEL = /^\s+class (\w+)$/
    # The YARD lines of a model file for one field: its name, its summary
    # and its type, like "Time" or "Array<UserV2>".
    FIELD = /^\s+# @!attribute \[r\] (\S+)\n.*\n\s+#   @return \[(.+), nil\]$/

    # The most changes to list. A pull request body can't hold many more.
    LIMIT = 100
    # The most other models to name on the line of a change they share.
    SAME = 3

    module_function

    # What the generated code under a root offers.
    def surface(root)
      read = ->(path) { File.read(File.join(root, path)) }
      allowed = JSON.parse(read[VALUES_PATH])
      events = read[EVENTS_PATH]
      entries = read[ENTRIES_PATH]
      # Each model's fields, keyed by the model's name. A field has a type
      # and limits: the values it allows, and the values that each key
      # inside it allows, under names like "field.key". A key that takes
      # any value has nil.
      models = Dir.glob("#{MODELS_PATH}/*.rb", base: root).sort.to_h do |path|
        source = read[path]
        model = source[MODEL, 1]
        limits = allowed["fields"].fetch(model, {})
        [model, source.scan(FIELD).to_h do |field, type|
          [field, {type:, limits: limits.select { |name, _| name.split(".").first == field }}]
        end]
      end
      # How each method is called, keyed by the call. `limits` has the
      # values its arguments allow, named like those of a field.
      # `operators` has the operators its filter arguments allow, and
      # `shown` those that examples show, for filters whose operators the
      # spec doesn't name.
      methods = JSON.parse(read[OPERATIONS_PATH]).to_h do |op|
        call = op.fetch("call")
        [call, signature(op).merge(
          limits: allowed["arguments"].fetch(call, {}),
          operators: allowed["operators"].fetch(call, {}),
          shown: allowed["example_operators"].fetch(call, {})
        )]
      end
      # What the gem hands to code that uses it: the models of events and
      # entries, and what methods return.
      handed = (events + entries).scan(MAPPED).flatten + methods.values.map { |method| method[:returns] }
      {
        events: events.scan(EVENT).flatten,
        entries: entries.scan(ENTRY).map { |action, version| "`#{action}` (version #{version})" },
        models:,
        methods:,
        read: read_models(models, handed)
      }
    end

    # The models that code using the gem can be handed: those named in the
    # given texts, and every model that a field of one of them can hold.
    def read_models(models, texts)
      found = []
      loop do
        names = texts.flat_map { |text| text.scan(/\w+/) }.uniq & (models.keys - found)
        return found if names.empty?

        found += names
        texts = names.flat_map { |name| models[name].values.map { |field| field[:type] } }
      end
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
      limits = kept_limits(before[:models], after[:models])
      [
        *(before[:events] - after[:events]).map { |type| "Webhook event `#{type}` was removed" },
        *(before[:entries] - after[:entries]).map { |entry| "Audit log entry #{entry} was removed" },
        *(before[:models].keys - after[:models].keys).map { |model| "Model `#{model}` was removed" },
        *field_changes(before[:models], after[:models]),
        *together(fewer_values(limits)),
        *method_changes(before[:methods], after[:methods]),
        # Last, as a new value is the least likely to break anything. These
        # are the first to be left out when the list is too long.
        *together(more_values(limits, after[:read]))
      ]
    end

    # Fields that were removed or changed type, in models that both have,
    # and keys inside fields that were removed. The fields of a removed
    # model aren't listed one by one.
    def field_changes(before, after)
      after.flat_map do |model, fields|
        before.fetch(model, {}).flat_map do |field, was|
          now = fields[field]
          next ["Field `#{model}##{field}` was removed"] unless now
          next ["Field `#{model}##{field}` changed type from `#{was[:type]}` to `#{now[:type]}`"] if was[:type] != now[:type]

          removed_keys(was[:limits], now[:limits]).map { |name| "Field `#{model}##{name}` was removed" }
        end
      end
    end

    # The keys inside a field or an argument that are gone, by names like
    # "field.key". `was` and `now` are its limits. Keys inside a removed key
    # aren't listed one by one.
    def removed_keys(was, now)
      (was.keys - now.keys).select do |name|
        parent = name.rpartition(".").first
        # A name without a dot is the field or argument itself.
        name.include?(".") && (!parent.include?(".") || now.key?(parent))
      end
    end

    # The limits to compare, as [model, name, was, now]: one for each field,
    # and each key inside a field, that was limited to some values and is
    # still there. `now` is nil when it allows any value. A field that
    # changed type is left out, as its old and new values can't be compared.
    def kept_limits(before, after)
      after.flat_map do |model, fields|
        before.fetch(model, {}).flat_map do |field, was|
          now = fields[field]
          next [] if now.nil? || now[:type] != was[:type]

          was[:limits].filter_map do |name, values|
            # A key that is gone is listed as removed.
            [model, name, values, now[:limits][name]] if values && (!name.include?(".") || now[:limits].key?(name))
          end
        end
      end
    end

    # Fields that allow fewer values than before, as [model, name, change].
    # Code that sends the field can no longer send a value, and code that
    # reads it waits for a value that no longer comes.
    def fewer_values(limits)
      limits.filter_map do |model, name, was, now|
        gone = was - (now || was)
        [model, name, "no longer allows #{quote(gone)}"] if gone.any?
      end
    end

    # Fields that allow more values than before, as [model, name, change].
    # Code that reads the field can meet a value it doesn't know. Only
    # models that code can be handed are listed, as a new value can't break
    # code that only sends the field.
    def more_values(limits, read)
      limits.filter_map do |model, name, was, now|
        next unless read.include?(model)

        if now.nil?
          [model, name, "now allows any value"]
        elsif (now - was).any?
          [model, name, "now also allows #{quote(now - was)}"]
        end
      end
    end

    # One line for each change. Models that repeat a field share a change
    # to it, so they are named on the same line.
    def together(changes)
      changes.group_by { |_, name, change| [name, change] }.map do |(name, change), same|
        model, *others = same.map(&:first)
        more = " and #{others.size - SAME} more" if others.size > SAME
        also = " (same in #{quote(others.first(SAME))}#{more})" if others.any?
        "Field `#{model}##{name}` #{change}#{also}"
      end
    end

    # Arguments of a method, and keys inside them, that allow fewer values
    # than before. Allowing more can't break a call, and nor can a limit on
    # a new argument or key.
    def argument_value_changes(name, was, now)
      now[:limits].filter_map do |arg, values|
        next unless values && was[:types].key?(arg.split(".").first)

        allowed = was[:limits][arg]
        if allowed
          "Method `#{name}` no longer allows #{quote(allowed - values)} for `#{arg}`" if (allowed - values).any?
        elsif !arg.include?(".") || was[:limits].key?(arg)
          "Method `#{name}` now only allows #{quote(values)} for `#{arg}`"
        end
      end
    end

    # Keys inside the arguments of a method that are gone, for arguments
    # that kept their type. A removed argument is listed already.
    def removed_argument_keys(name, was, now)
      removed_keys(was[:limits], now[:limits]).filter_map do |key|
        arg = key.split(".").first
        "Method `#{name}` no longer takes `#{key}`" if was[:types][arg] == now[:types][arg]
      end
    end

    # Filter arguments of a method that lost an operator, like `not_in` in
    # `status: {not_in: [...]}`. The spec only names operators in its text,
    # so an argument whose text no longer names any is listed too.
    def operator_changes(name, was, now)
      was[:operators].filter_map do |arg, operators|
        next unless now[:types].key?(arg)

        allowed = now[:operators][arg]
        if allowed.nil?
          "Method `#{name}` no longer says which operators `#{arg}` allows"
        elsif (operators - allowed).any?
          "Method `#{name}` no longer allows #{quote(operators - allowed)} as an operator for `#{arg}`"
        end
      end
    end

    # Filter arguments whose examples show fewer operators than before.
    # The spec names no operators for these, so its examples are all there
    # is to go on. An operator that is no longer shown may still work, but
    # not when the spec now names the operators and leaves it out.
    def example_changes(name, was, now)
      was[:shown].filter_map do |arg, operators|
        # A removed argument is listed already.
        next unless now[:types].key?(arg)

        named = now[:operators][arg]
        gone = operators - (named || now[:shown].fetch(arg, []))
        next if gone.empty?

        if named
          "Method `#{name}` no longer allows #{quote(gone)} as an operator for `#{arg}`"
        else
          "Method `#{name}` no longer shows #{quote(gone)} as an operator for `#{arg}` in its examples"
        end
      end
    end

    def quote(values)
      values.map { |value| "`#{value}`" }.join(", ")
    end

    # Methods that were removed, and methods that can no longer be used the
    # same way: their positional arguments changed, they lost a keyword
    # argument or a key inside one, they need a new one, an argument changed
    # type or allows fewer values or operators, or they return something
    # else.
    def method_changes(before, after)
      before.flat_map do |name, was|
        now = after[name]
        next ["Method `#{name}` was removed"] unless now

        positional = [was, now].map { |args| "`(#{args[:positional].join(", ")})`" }
        [
          *("Method `#{name}` changed its positional arguments from #{positional.first} to #{positional.last}" if positional.uniq.size > 1),
          *(was[:required] + was[:optional] - now[:required] - now[:optional]).map { |arg| "Method `#{name}` no longer takes `#{arg}:`" },
          *removed_argument_keys(name, was, now),
          *(now[:required] - was[:required]).map { |arg| "Method `#{name}` now needs `#{arg}:`" },
          *was[:types].filter_map do |arg, type|
            now_type = now[:types].fetch(arg, type)
            "Method `#{name}` changed the type of argument `#{arg}` from `#{type}` to `#{now_type}`" if now_type != type
          end,
          *argument_value_changes(name, was, now),
          *operator_changes(name, was, now),
          *example_changes(name, was, now),
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
