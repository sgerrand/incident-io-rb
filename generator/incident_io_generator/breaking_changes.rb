# frozen_string_literal: true

module IncidentIoGenerator
  # Finds changes in a newer copy of the generated code that can break code
  # that uses the gem, so the update workflow can list them in its pull
  # request. It reads the manifests that Writer writes next to the code.
  # It finds:
  #
  # - a webhook event type, audit log entry type, model, model field or
  #   resource method that was removed
  # - a webhook event type or audit log entry type with another model
  # - a model field, or a key inside one, that changed type or allows other
  #   values
  # - a resource that `client.<name>` reaches in another API version
  # - a resource method whose arguments or return type changed, or with an
  #   argument, or a key inside one, that changed type or allows fewer
  #   values or operators
  module BreakingChanges
    MODELS_PATH = "spec/fixtures/models.json"
    OPERATIONS_PATH = "spec/fixtures/operations.json"
    VALUES_PATH = "spec/fixtures/allowed_values.json"
    # The manifests that are read, relative to the repository root.
    PATHS = [MODELS_PATH, OPERATIONS_PATH, VALUES_PATH].freeze

    # The most changes to list. A pull request body can't hold many more.
    LIMIT = 100
    # The most other models to name on the line of a change they share.
    SAME = 3

    module_function

    # What the generated code under a root offers, from its manifests.
    def surface(root)
      read = ->(path) { JSON.parse(File.read(File.join(root, path))) }
      allowed = read[VALUES_PATH]
      manifest = read[MODELS_PATH]
      # The model of each webhook event type, and of each audit log entry
      # type by action, then by version.
      events = manifest.fetch("webhook_events")
      entries = manifest.fetch("audit_log_entries")
      # Each model, keyed by its name. `types` has the type of each field,
      # like "Time" or "Array<UserV2>", and of each key inside a field,
      # under a name like "field.key". `limits` has the values that each
      # of those allows. One that allows any value isn't in it.
      models = manifest.fetch("models").to_h do |model, types|
        [model, {types:, limits: allowed["fields"].fetch(model, {})}]
      end
      # How each method is called, keyed by the call. `types` and `limits`
      # are those of its arguments, named like those of a model's fields.
      # `operators` has the operators its filter arguments allow, and
      # `shown` those that examples show, for filters whose operators the
      # spec doesn't name.
      operations = read[OPERATIONS_PATH]
      methods = operations.to_h do |op|
        call = op.fetch("call")
        [call, signature(op).merge(
          limits: allowed["arguments"].fetch(call, {}),
          operators: allowed["operators"].fetch(call, {}),
          shown: allowed["example_operators"].fetch(call, {})
        )]
      end
      # What the gem hands to code that uses it: the models of events and
      # entries, and what methods return.
      handed = events.values + entries.values.flat_map(&:values) + methods.values.map { |method| method[:returns] }
      {
        # The model of each event and entry type, keyed by how the type is
        # named in a change.
        events: events.transform_keys { |type| "`#{type}`" },
        entries: entries.flat_map do |action, versions|
          versions.map { |version, model| ["`#{action}` (version #{version})", model] }
        end.to_h,
        models:,
        methods:,
        # What `client.<resource>` reaches, keyed by resource: the version
        # it uses, and that version's methods as called through it.
        newest: operations.select { |op| op.fetch("newest") }.group_by { |op| op["resource"] }.transform_values do |ops|
          {
            version: ops.first["version"],
            methods: ops.to_h { |op| ["client.#{op["resource"]}.#{op["method"]}", methods.fetch(op["call"])] }
          }
        end,
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
        texts = names.flat_map { |name| models[name][:types].values }
      end
    end

    # A method's arguments, their types and what it returns, from its entry
    # in the operations manifest.
    def signature(op)
      types = op.fetch("arg_types")
      # A name with a dot is a key inside an argument.
      args = types.keys.reject { |name| name.include?(".") }
      # The manifest has the positional arguments first.
      positional = args.first(op.fetch("path_args").size)
      required = op.fetch("keyword_args").keys
      {positional:, required:, optional: args - positional - required, types:, returns: op.fetch("returns")}
    end

    # The names in `was` to compare with `now`: fields or arguments, and
    # each key inside one whose parents all kept their type. Both map names
    # to types. What is inside something that was removed or changed type
    # isn't compared, as that is listed already.
    def comparable(was, now)
      was.keys.select do |name|
        parts = name.split(".")
        (1...parts.size).all? do |size|
          parent = parts.first(size).join(".")
          now[parent] == was[parent]
        end
      end
    end

    # The breaking changes from `before` to `after`, one line each. Both
    # come from #surface.
    def changes(before, after)
      limits = kept_limits(before[:models], after[:models])
      [
        *type_changes("Webhook event", before[:events], after[:events]),
        *type_changes("Audit log entry", before[:entries], after[:entries]),
        *(before[:models].keys - after[:models].keys).map { |model| "Model `#{model}` was removed" },
        *field_changes(before[:models], after[:models]),
        *together(fewer_values(limits)),
        *accessor_changes(before[:newest], after[:newest]),
        *method_changes(before[:methods], after[:methods]),
        # Last, as a new value is the least likely to break anything. These
        # are the first to be left out when the list is too long.
        *together(more_values(limits, after[:read]))
      ]
    end

    # Event or entry types that were removed, and types that now come with
    # another model. Code that reads the old model's fields from one of
    # those can break.
    def type_changes(kind, before, after)
      before.filter_map do |type, was|
        now = after[type]
        if now.nil?
          "#{kind} #{type} was removed"
        elsif now != was
          "#{kind} #{type} changed its model from `#{was}` to `#{now}`"
        end
      end
    end

    # Fields, and keys inside fields, that were removed or changed type, in
    # models that both have. The fields of a removed model aren't listed
    # one by one.
    def field_changes(before, after)
      before.slice(*after.keys).flat_map do |model, was|
        now = after[model][:types]
        comparable(was[:types], now).filter_map do |name|
          type = was[:types][name]
          if !now.key?(name)
            "Field `#{model}##{name}` was removed"
          elsif now[name] != type
            "Field `#{model}##{name}` changed type from `#{type}` to `#{now[name]}`"
          end
        end
      end
    end

    # The limits to compare, as [model, name, was, now]: one for each field,
    # and each key inside a field, that was limited to some values and is
    # still there with the same type. `now` is nil when it allows any
    # value. The old and new values of one that changed type can't be
    # compared.
    def kept_limits(before, after)
      before.slice(*after.keys).flat_map do |model, was|
        now = after[model]
        comparable(was[:types], now[:types]).filter_map do |name|
          values = was[:limits][name]
          [model, name, values, now[:limits][name]] if values && now[:types][name] == was[:types][name]
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
        next unless was[:types].key?(arg)

        allowed = was[:limits][arg]
        if allowed.nil?
          "Method `#{name}` now only allows #{quote(values)} for `#{arg}`"
        elsif (allowed - values).any?
          "Method `#{name}` no longer allows #{quote(allowed - values)} for `#{arg}`"
        end
      end
    end

    # Keys inside the arguments of a method that are gone. A removed
    # argument is listed already.
    def removed_argument_keys(name, was, now)
      (comparable(was[:types], now[:types]) - now[:types].keys).filter_map do |key|
        "Method `#{name}` no longer takes `#{key}`" if key.include?(".")
      end
    end

    # Arguments of a method, and keys inside them, that changed type.
    def argument_type_changes(name, was, now)
      comparable(was[:types], now[:types]).filter_map do |arg|
        type = was[:types][arg]
        now_type = now[:types].fetch(arg, type)
        "Method `#{name}` changed the type of argument `#{arg}` from `#{type}` to `#{now_type}`" if now_type != type
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

    # Resources that `client.<resource>` reaches in another version than
    # before, and what that changes for each method called through it.
    # Changes inside a version are listed under its own calls, like
    # `client.v2.<resource>.<method>`, and so are the methods of a resource
    # that is gone.
    def accessor_changes(before, after)
      before.flat_map do |resource, was|
        now = after[resource]
        next [] if now.nil? || now[:version] == was[:version]

        [
          "Resource `client.#{resource}` now uses #{now[:version]} instead of #{was[:version]}",
          *method_changes(was[:methods], now[:methods])
        ]
      end
    end

    # Methods that were removed, and methods that can no longer be used the
    # same way: their positional arguments changed, they lost a keyword
    # argument or a key inside one, they need a new one, an argument or a
    # key inside one changed type or allows fewer values or operators, or
    # they return something else.
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
          *argument_type_changes(name, was, now),
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
