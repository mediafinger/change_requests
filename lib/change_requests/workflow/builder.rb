# frozen_string_literal: true

module ChangeRequests
  class Workflow
    # The `w` of `op.workflow do |w| … end` (§6.4, §6.9). It builds a description and nothing else:
    # `Commands::Create` materialises whatever it is handed, and this is the only producer.
    #
    # Everything it refuses, it refuses at declaration time - in an initializer, where the mistake
    # was made - rather than at creation time, where a unique index or a NOT NULL column would.
    class Builder
      def self.build(operation_key:)
        builder = new(operation_key)
        yield(builder)

        builder.to_workflow
      end

      def initialize(operation_key)
        @operation_key = operation_key
        @stages        = []
      end

      def stage(name, satisfied_by: :any_quorum, **quorum_options, &)
        stage_name = normalized_name(name)
        mode       = normalized_satisfied_by(stage_name, satisfied_by)
        builder    = StageBuilder.new(operation_key: operation_key, stage_name: stage_name)

        collect(builder, stage_name, quorum_options, &)

        stages << Stage.new(name: stage_name, position: stages.size + 1, satisfied_by: mode,
                            quorums: builder.quorums)
      end

      def to_workflow
        refuse_empty_workflow if stages.empty?

        Workflow.new(stages)
      end

      private

      attr_reader :operation_key, :stages

      def collect(builder, stage_name, quorum_options, &block)
        return builder.quorum(**quorum_options) unless block

        refuse_mixed(stage_name) if quorum_options.any?

        block.call(builder)

        refuse_empty_stage(stage_name) if builder.quorums.empty?
      end

      def normalized_name(name)
        stage_name = name.to_s

        refuse_nameless_stage(name) if stage_name.strip.empty?
        refuse_duplicate_stage(stage_name) if stages.any? { |stage| stage.name == stage_name }

        stage_name
      end

      def normalized_satisfied_by(stage_name, satisfied_by)
        mode = satisfied_by&.to_sym

        refuse_satisfied_by(stage_name, satisfied_by) unless SATISFIED_BY.include?(mode)

        mode
      end

      def prefix
        "ChangeRequests operation #{operation_key.inspect}"
      end

      def refuse_nameless_stage(name)
        fail ConfigurationError,
             "#{prefix}: op.workflow stage #{name.inspect} needs a name. change_request_stages.name is " \
             "NOT NULL, and the name is the identifier the timeline and the locale file read (§5.2, §5.9)."
      end

      def refuse_duplicate_stage(stage_name)
        fail ConfigurationError,
             "#{prefix}: op.workflow declares stage #{stage_name.to_sym.inspect} twice. Stage names are " \
             "unique within a request, and the unique index would refuse the second row (§5.2)."
      end

      def refuse_satisfied_by(stage_name, satisfied_by)
        fail ConfigurationError,
             "#{prefix}: op.workflow stage #{stage_name.to_sym.inspect} satisfied_by: #{satisfied_by.inspect}. " \
             "Expected #{SATISFIED_BY.map(&:inspect).join(" or ")} (§5.2)."
      end

      def refuse_mixed(stage_name)
        fail ConfigurationError,
             "#{prefix}: op.workflow stage #{stage_name.to_sym.inspect} takes either a block of quorums or " \
             "one inline quorum, not both. Move the inline keywords into a `q.quorum` (§6.9)."
      end

      def refuse_empty_stage(stage_name)
        fail ConfigurationError,
             "#{prefix}: op.workflow stage #{stage_name.to_sym.inspect} declares no quorum. A stage nobody " \
             "can satisfy would leave the request pending until it expired (§5.3)."
      end

      def refuse_empty_workflow
        fail ConfigurationError,
             "#{prefix}: op.workflow declares no stage, so a request against this operation could never " \
             "be approved. Declare at least one `w.stage` (§6.4)."
      end
    end
  end
end
