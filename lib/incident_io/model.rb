# frozen_string_literal: true

module IncidentIo
  # Builds immutable model classes on top of `Data`.
  #
  #   Severity = IncidentIo::Model.define(id: :string, name: :string, rank: :integer)
  #   Incident = IncidentIo::Model.define(
  #     id: :string,
  #     created_at: :time,
  #     severity: -> { Severity },           # lazy, so models can refer to each other
  #     tags: [:string],                     # array of a type
  #     metadata: Model.map_of(:string)      # object with free-form keys
  #   )
  #
  #   incident = Incident.from_api(json_hash)
  #   incident.severity.name
  #   incident[:field_added_later]           # read any field in the raw payload
  #   incident.to_api                        # back to a JSON-ready hash
  #
  # Types: :string, :integer, :float, :boolean, :time, :date, :any, a model
  # class, a Proc returning a type, `[type]` for arrays and `map_of(type)`.
  #
  # API fields whose names clash with core Ruby methods (e.g. `class`,
  # `method`, `members`) get a trailing underscore: `class_`. Characters that
  # can't appear in a method name become underscores:
  # `private_alert.alert_created_v1` => `private_alert_alert_created_v1`.
  module Model
    MapOf = Data.define(:type)

    # A type for objects with free-form keys, all with values of one type
    #
    # @param type [Object] the type of each value
    # @return [MapOf]
    def self.map_of(type)
      MapOf.new(type: type)
    end

    # Builds a model class
    #
    # @param schema [Hash{Symbol => Object}] API field name => type
    # @yield optional methods to add to the class, evaluated in the class
    # @return [Class] a Data subclass with ClassMethods and InstanceMethods
    def self.define(**schema, &block)
      fields = schema.to_h { |api_name, type| [member_name(api_name), [api_name.to_s, type]] }.freeze
      members = fields.keys

      klass = Data.define(*members)
      klass.extend(ClassMethods)
      klass.include(InstanceMethods)
      klass.instance_variable_set(:@fields, fields)

      # Every field is optional: the API leaves some out and adds others.
      klass.define_method(:initialize) do |raw: nil, **attrs|
        unknown = attrs.keys - members
        raise ArgumentError, "unknown keyword#{"s" if unknown.size > 1}: #{unknown.join(", ")}" if unknown.any?

        @_raw = raw.nil? ? nil : raw.dup.freeze
        super(**members.to_h { |m| [m, attrs[m]] })
      end

      klass.class_eval(&block) if block
      klass
    end

    # The Ruby method name for an API field name
    #
    # @param api_name [String, Symbol]
    # @return [Symbol]
    def self.member_name(api_name)
      name = api_name.to_s.gsub(/[^A-Za-z0-9_]/, "_").to_sym
      reserved_names.include?(name) ? :"#{name}_" : name
    end

    # Method names that fields can't use, as models already define them
    #
    # @return [Array<Symbol>]
    def self.reserved_names
      @reserved_names ||= (Data.instance_methods + InstanceMethods.instance_methods + %i[initialize]).freeze
    end

    # Converts a parsed JSON value to a field's type
    #
    # @param type [Object] a type as described in the Model docs
    # @param value [Object]
    # @return [Object]
    def self.coerce(type, value)
      return nil if value.nil?

      case type
      when Proc then coerce(type.call, value)
      when Array then Array(value).map { |v| coerce(type.first, v) }
      when MapOf then value.to_h { |k, v| [k, coerce(type.type, v)] }
      when :time then Util.parse_time(value) || value
      when :date then parse_date(value)
      when :float then value.is_a?(Integer) ? value.to_f : value
      when ClassMethods then type.from_api(value)
      else value
      end
    end

    # Parses an ISO 8601 date, keeping the original value if it isn't one
    #
    # @param value [Object]
    # @return [Date, Object]
    def self.parse_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      value
    end

    # Added to every model class.
    module ClassMethods
      # The model's fields
      #
      # @return [Hash{Symbol => Array(String, Object)}] Ruby member name =>
      #   [API field name, type]
      def fields
        @fields
      end

      # Builds a model from a parsed JSON hash
      #
      # @param hash [Hash, nil] a model is returned unchanged
      # @return [Object, nil] the model, or nil for nil
      def from_api(hash)
        return nil if hash.nil?
        return hash if hash.is_a?(self)

        attrs = fields.to_h do |member, (api_name, type)|
          [member, Model.coerce(type, hash[api_name])]
        end
        new(raw: hash, **attrs)
      end
    end

    # Added to every model instance.
    module InstanceMethods
      # The payload this model was built from
      #
      # @return [Hash, nil] nil if the model was built by hand
      def raw
        @_raw
      end

      # Reads a field by its API name from the raw payload
      #
      # Useful for fields the API has added since this gem was generated.
      #
      # @param key [String, Symbol]
      # @return [Object, nil]
      def [](key)
        raw&.[](key.to_s)
      end

      # A hash ready for JSON, keyed by API field names
      #
      # Fields that are nil are left out.
      #
      # @return [Hash{String => Object}]
      def to_api
        model_class = _ = self.class #: ClassMethods
        out = {} #: Hash[String, untyped]
        model_class.fields.each do |member, (api_name, _type)|
          value = public_send(member)
          out[api_name] = Util.serialize(value) unless value.nil?
        end
        out
      end
    end
  end
end
