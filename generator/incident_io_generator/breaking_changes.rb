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

    # The most changes to list, and the most characters they can take up. A
    # pull request body holds 65,536 characters, and needs room for the
    # rest of its text too.
    LIMIT = 100
    SIZE = 50_000
    # The most values to name in one change.
    VALUES = 20
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
    # A Set, as it is looked up for every limit of every field.
    def read_models(models, texts)
      found = []
      loop do
        names = texts.flat_map { |text| text.scan(/\w+/) }.uniq & (models.keys - found)
        return found.to_set if names.empty?

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
        parts = Types.name_parts(name)
        (1...parts.size).all? do |size|
          parent = parts.first(size).join(".")
          now[parent] == was[parent]
        end
      end
    end

    # The names in `was` that are still there in `now` with the same type,
    # and whose parents all kept their type too. Only the values of these
    # can be compared. Takes the names from #comparable when the caller has
    # them already. A Set, as the checks of operators look names up in it.
    def unchanged(was, now, names = comparable(was, now))
      names.select { |name| now[name] == was[name] }.to_set
    end

    # The names in `was` that were removed or changed type, and whose
    # parents all kept their type, as [name, type, type now]. The type now
    # is nil for one that was removed. Takes the names from #comparable
    # when the caller has them already.
    def retyped(was, now, names = comparable(was, now))
      names.filter_map { |name| [name, was[name], now[name]] if now[name] != was[name] }
    end

    # The breaking changes from `before` to `after`, one line each. Both
    # come from #surface.
    def changes(before, after)
      limits = field_limits(before[:models], after[:models])
      [
        *type_changes("Webhook event", before[:events], after[:events]),
        *type_changes("Audit log entry", before[:entries], after[:entries]),
        *(before[:models].keys - after[:models].keys).map { |model| "Model `#{model}` was removed" },
        *field_changes(before[:models], after[:models]),
        *together(fewer_values(limits)),
        *method_changes(before[:methods], after[:methods]),
        # After the methods, as a new version can add a line for each of
        # its methods, which would push their own changes out of the list.
        *accessor_changes(before[:newest], after[:newest]),
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
        retyped(was[:types], after[model][:types]).map do |name, type, now|
          now ? "Field `#{model}##{name}` changed type from `#{type}` to `#{now}`" : "Field `#{model}##{name}` was removed"
        end
      end
    end

    # The limits to compare in a model or a method, as [name, was, now]:
    # one for each field or argument, and each key inside one, that is
    # still there with the same type, and was or is limited to some values.
    # `was` or `now` is nil when it allows any value. The old and new values
    # of one that changed type can't be compared. Takes the names from
    # #unchanged when the caller has them already.
    def kept_limits(was, now, kept = unchanged(was[:types], now[:types]))
      kept.filter_map do |name|
        values = [was, now].map { |side| side[:limits][name] }
        [name, *values] if values.any?
      end
    end

    # The limits to compare for fields, as [model, name, was, now], in
    # models that both have.
    def field_limits(before, after)
      before.slice(*after.keys).flat_map do |model, was|
        kept_limits(was, after[model]).map { |limit| [model, *limit] }
      end
    end

    # How a field or argument that allows fewer values than before changed,
    # or nil when it doesn't. One that allowed any value and is now limited
    # to some is listed too. Code that sends it can no longer send a value,
    # and code that reads it waits for a value that no longer comes.
    def fewer(was, now)
      if was.nil?
        "now only allows #{quote(now)}"
      elsif !(was - (now || was)).empty?
        "no longer allows #{quote(was - now)}"
      end
    end

    # Fields that allow fewer values than before, as [model, name, change].
    def fewer_values(limits)
      limits.filter_map do |model, name, was, now|
        change = fewer(was, now)
        [model, name, change] if change
      end
    end

    # Fields that allow more values than before, as [model, name, change].
    # Code that reads the field can meet a value it doesn't know. Only
    # models that code can be handed are listed, as a new value can't break
    # code that only sends the field.
    def more_values(limits, read)
      limits.filter_map do |model, name, was, now|
        # A field that allowed any value before can't allow more.
        next unless was && read.include?(model)

        if now.nil?
          [model, name, "now allows any value"]
        elsif !(now - was).empty?
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
    # a new argument or key. One that changed type is listed for that. Its
    # old and new values can't be compared. Takes the names from #unchanged
    # when the caller has them already, as do the checks of operators.
    def argument_value_changes(name, was, now, kept = unchanged(was[:types], now[:types]))
      kept_limits(was, now, kept).filter_map do |arg, allowed, values|
        change = fewer(allowed, values)
        "Method `#{name}` #{change} for `#{arg}`" if change
      end
    end

    # Arguments of a method, and keys inside them, that changed type, and
    # keys inside them that are gone, from #retyped. A removed argument is
    # listed already.
    def argument_type_changes(name, retyped)
      retyped.filter_map do |arg, type, now|
        if now
          "Method `#{name}` changed the type of argument `#{arg}` from `#{type}` to `#{now}`"
        elsif arg.include?(".")
          "Method `#{name}` no longer takes `#{arg}`"
        end
      end
    end

    # Filter arguments of a method that lost an operator, like `not_in` in
    # `status: {not_in: [...]}`. The spec only names operators in its text,
    # so an argument whose text no longer names any is listed too. One that
    # was removed or changed type is listed for that already.
    def operator_changes(name, was, now, kept = unchanged(was[:types], now[:types]))
      was[:operators].filter_map do |arg, operators|
        next unless kept.include?(arg)

        allowed = now[:operators][arg]
        if allowed.nil?
          "Method `#{name}` no longer says which operators `#{arg}` allows"
        elsif (operators - allowed).any?
          lost_operators(name, arg, operators - allowed)
        end
      end
    end

    # Filter arguments whose examples show fewer operators than before.
    # The spec names no operators for these, so its examples are all there
    # is to go on. An operator that is no longer shown may still work, but
    # not when the spec now names the operators and leaves it out.
    def example_changes(name, was, now, kept = unchanged(was[:types], now[:types]))
      was[:shown].filter_map do |arg, operators|
        # One that was removed or changed type is listed already.
        next unless kept.include?(arg)

        named = now[:operators][arg]
        gone = operators - (named || now[:shown].fetch(arg, []))
        next if gone.empty?

        if named
          lost_operators(name, arg, gone)
        else
          "Method `#{name}` no longer shows #{quote(gone)} #{as_operators(gone)} for `#{arg}` in its examples"
        end
      end
    end

    # The change for a filter argument of a method that no longer allows
    # some operators.
    def lost_operators(name, arg, gone)
      "Method `#{name}` no longer allows #{quote(gone)} #{as_operators(gone)} for `#{arg}`"
    end

    # How a change names the operators it lists.
    def as_operators(operators)
      (operators.size > 1) ? "as operators" : "as an operator"
    end

    # The values as they are named in a change. A value can be false or
    # nil, which the spec writes as null. Past the first few, they are only
    # counted.
    def quote(values)
      named = values.first(VALUES).map { |value| code(value.nil? ? "null" : value.to_s) }
      more = " and #{values.size - VALUES} more" if values.size > VALUES
      "#{named.join(", ")}#{more}"
    end

    # Text as inline code. Its fence of backticks is longer than any run of
    # backticks in the text, so none of those can end it. Text with a
    # backtick gets a space at each end, which Markdown takes off, so one
    # at the start or end can't join the fence.
    def code(text)
      fence = "`" * (text.scan(/`+/).map(&:size).max.to_i + 1)
      text = " #{text} " if text.include?("`")
      "#{fence}#{text}#{fence}"
    end

    # A change as one line of Markdown. A line break in a name or value
    # would end the list, so it becomes a space. A `-->` would end a mark
    # like `<!-- breaking-changes:end -->` that the update workflow puts
    # around the list, so a zero-width space goes inside it.
    def one_line(change)
      change.gsub(/\R/, " ").gsub("-->", "--\u200B>")
    end

    # Resources that are gone in every version, and resources that
    # `client.<resource>` reaches in another version than before, with what
    # that changes for each method called through it. Changes inside a
    # version are listed under its own calls, like
    # `client.v2.<resource>.<method>`, and so are the methods of a resource
    # that is gone.
    def accessor_changes(before, after)
      before.flat_map do |resource, was|
        now = after[resource]
        next ["Resource `client.#{resource}` was removed"] if now.nil?
        next [] if now[:version] == was[:version]

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
        names = comparable(was[:types], now[:types])
        kept = unchanged(was[:types], now[:types], names)
        [
          *("Method `#{name}` changed its positional arguments from #{positional.first} to #{positional.last}" if positional.uniq.size > 1),
          *(was[:required] + was[:optional] - now[:required] - now[:optional]).map { |arg| "Method `#{name}` no longer takes `#{arg}:`" },
          *(now[:required] - was[:required]).map { |arg| "Method `#{name}` now needs `#{arg}:`" },
          *argument_type_changes(name, retyped(was[:types], now[:types], names)),
          *argument_value_changes(name, was, now, kept),
          *operator_changes(name, was, now, kept),
          *example_changes(name, was, now, kept),
          *("Method `#{name}` changed what it returns from `#{was[:returns]}` to `#{now[:returns]}`" if was[:returns] != now[:returns])
        ]
      end
    end

    # A Markdown section listing the breaking changes from the generated
    # code under before_root to the code under after_root, or an empty
    # string when there are none.
    def report(before_root, after_root)
      lines = changes(surface(before_root), surface(after_root)).map { |change| one_line(change) }
      return "" if lines.empty?

      # Each line takes up its change, with "- " before it and a line break
      # after it.
      size = 0
      shown = lines.first(LIMIT).take_while { |line| (size += line.size + 3) <= SIZE }
      shown << "and #{lines.size - shown.size} more" if shown.size < lines.size

      <<~MARKDOWN
        ## Breaking changes

        The latest spec removes or changes these. Each one can break code that uses the gem.

        #{shown.map { |line| "- #{line}" }.join("\n")}
      MARKDOWN
    end
  end
end
