# frozen_string_literal: true

module IncidentIoGenerator
  # Turns names from the spec into Ruby names.
  module Naming
    RUBY_KEYWORDS = %w[
      BEGIN END __ENCODING__ __FILE__ __LINE__ alias and begin break case class def defined?
      do else elsif end ensure false for if in module next nil not or redo rescue retry
      return self super then true undef unless until when while yield
    ].freeze

    module_function

    # "IncidentV2" => "incident_v2", "Follow-ups" => "follow_ups",
    # "IPAllowlists" => "ip_allowlists", "CreateHTTP" => "create_http"
    def underscore(name)
      name.to_s
        .gsub(/[^A-Za-z0-9]+/, "_")
        .gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .downcase
        .squeeze("_")
        .delete_prefix("_")
        .delete_suffix("_")
    end

    # "follow_ups" => "FollowUps"
    def camelize(name)
      underscore(name).split("_").map(&:capitalize).join
    end

    # True when the name can be used as a Ruby keyword argument and local.
    def safe_identifier?(name)
      name.match?(/\A[a-z_][a-z0-9_]*\z/) && !RUBY_KEYWORDS.include?(name)
    end
  end
end
