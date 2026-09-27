# frozen_string_literal: true

module IncidentIo
  # The type of NOT_GIVEN.
  class NotGiven
    def inspect
      "IncidentIo::NOT_GIVEN"
    end
    alias_method :to_s, :inspect
  end

  # Default for optional request body arguments. Generated methods leave
  # arguments that weren't passed out of the request, and send nil as null:
  #
  #   client.schedules.update(id, name: "New name")    # only changes the name
  #   client.schedules.update(id, name: "x", description: nil)  # clears it
  NOT_GIVEN = NotGiven.new.freeze
end
