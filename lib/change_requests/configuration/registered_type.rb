# frozen_string_literal: true

module ChangeRequests
  class Configuration
    # Shared by actor_type and tenant_type. The registration list is at once the `*_type` allowlist
    # (§5.7), the label source and the per-type key cast, so a typo fails at boot.
    class RegisteredType
      KEY_TYPES   = %i(uuid integer string).freeze
      UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      attr_reader :name
      attr_accessor :key_type, :label
      attr_writer :finder

      def initialize(name)
        @name     = name.to_s
        @key_type = :integer
        @label    = nil
        @finder   = nil
      end

      # The batch resolver `CollectionPresenter` uses, so a page of requests costs one query per
      # actor type rather than one per row (§11).
      #
      #   t.finder = ->(ids) { User.kept.includes(:team).where(id: ids) }
      #
      # Defaults to `Klass.where(id: ids)` derived from the registered name, and **resolves the
      # class at call time**: a reloading application redefines it, and holding one here would be
      # the mistake ADR-0025 records about services. A name that no longer resolves finds nothing,
      # which is not an error - the labels are on the rows already.
      def finder
        @finder || ->(ids) { model&.where(id: ids) || [] }
      end

      def model
        name.safe_constantize
      end

      # `*_id` is always a String (§5.7), so finding the record means casting it back to whatever
      # the host's primary key actually is. Anything that will not cast is **dropped**, never
      # passed to the finder and never raised: a five-year-old row holding an id from a schema that
      # has since changed leaves an unresolved ref, not a 500 (Q2).
      def cast_id(id)
        case key_type
        when :integer then Integer(id, exception: false)
        when :uuid    then id.to_s if id.to_s.match?(UUID_FORMAT)
        else id
        end
      end

      # Returns an array of human-readable problems; empty when the registration is sound.
      def problems
        [key_type_problem, label_problem].compact
      end

      private

      def key_type_problem
        return if KEY_TYPES.include?(key_type)

        "#{describe} has key_type #{key_type.inspect}. " \
          "Expected one of #{KEY_TYPES.map(&:inspect).join(", ")}."
      end

      def label_problem
        return if label.respond_to?(:call)

        "#{describe} needs a label, for example " \
          "`t.label = ->(record) { record.name }`. Labels are snapshotted onto every request, " \
          "approval and event, so a request stays readable after the record is deleted (§5.7)."
      end

      def describe
        "#{self.class.name.split("::").last} #{name.inspect}"
      end
    end
  end
end
