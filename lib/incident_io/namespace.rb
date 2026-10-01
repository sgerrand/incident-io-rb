# frozen_string_literal: true

module IncidentIo
  module Resources
    # Base class for the generated V1::Namespace, V2::Namespace and so on,
    # which hold every resource of one API version.
    class Namespace
      # Creates the namespace for a client
      #
      # @param client [IncidentIo::Client]
      def initialize(client)
        @client = client
        @resources = {}
      end

      # A short description that leaves out the client
      #
      # @return [String]
      def inspect
        "#<#{self.class.name}>"
      end

      private

      # The resource of a class, created the first time it is used
      #
      # @param klass [Class] a Resource subclass
      # @return [Resource]
      def resource(klass)
        @resources[klass] ||= klass.new(@client)
      end
    end
  end
end
