# frozen_string_literal: true

module ChangeRequests
  # Resolves a whole page of `ActorRef`s in **one query per actor type** (§11).
  #
  #   ActorResolver.call(presenters.flat_map(&:actor_refs))
  #
  # Three actor classes on a page of twenty-five requests cost three queries, not seventy-five.
  # That is the entire reason `CollectionPresenter` owns eager loading: fixing the N+1 once, where
  # the refs are, rather than in every view that renders one.
  #
  # It fills each ref's memo, so nothing resolves itself afterwards - and refs a caller has already
  # resolved are skipped rather than queried again.
  class ActorResolver
    def self.call(refs)
      new(refs).call
    end

    def initialize(refs)
      @refs = Array(refs).flatten.compact
    end

    # The refs it was given, now answered.
    def call
      refs.reject(&:resolution_known?).group_by(&:type).each { |type, group| resolve(type, group) }

      refs
    end

    private

    attr_reader :refs

    def resolve(type, group)
      registered = ChangeRequests.registered_type(type)

      # Nobody registered it, so nothing can find it. The labels are already on the rows, so the
      # page still renders - it simply renders them as deleted (§11).
      return group.each { |ref| ref.resolve_with(nil) } if registered.nil?

      found = fetch(registered, group).index_by { |record| record.id.to_s }

      group.each { |ref| ref.resolve_with(found[ref.id]) }
    end

    # The finder is called **once** per type, with every id of that type, and never with an id that
    # would not cast - a host's finder should not have to defend against a malformed one.
    def fetch(registered, group)
      ids = group.filter_map { |ref| registered.cast_id(ref.id) }.uniq

      return [] if ids.empty?

      Array(registered.finder.call(ids))
    end
  end
end
