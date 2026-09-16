# frozen_string_literal: true

module ChangeRequests
  # What comes back out of every actor reader, and what every presenter and view receives (§9.1).
  #
  #   ref = request.requester
  #   ref.label      # the live label if the record still resolves, else the snapshot
  #   ref.deleted?   # drives the "(deleted)" affordance, and never raises
  #
  # A plain class rather than a `Data`: `record` resolves lazily and memoises, and `label` depends
  # on it. The stored triple is always complete, so every question below is answerable with no
  # query at all - resolution buys a fresh label and a link, and nothing else (§11).
  class ActorRef
    # Distinguishes "not looked yet" from "looked, found nothing". Without it a deleted actor is
    # re-queried on every call.
    UNRESOLVED = Object.new.freeze
    private_constant :UNRESOLVED

    attr_reader :type, :id, :snapshot, :identity

    # `record:` is what M4-2's batch loading injects: a collection resolves every ref of a page in
    # one query per actor type and hands each one its answer, so nothing resolves itself.
    def initialize(type:, id:, record: UNRESOLVED, **columns)
      @type     = type&.to_s
      @id       = id&.to_s
      @snapshot = columns[:label]
      @identity = columns[:identity]
      @record   = record

      # Only the keys this reference actually carries, so `to_h` is what the reader returned before
      # ActorRef existed: an eligibility row has no label, and only two references have an identity.
      @columns = columns.slice(:label, :identity)
    end

    # §19.5. `:live` prefers the record and falls back to the snapshot; `:snapshot` never resolves
    # at all, which is the only way to render a page with no query against the host's tables.
    def label
      return snapshot unless live_labels? && resolved?

      registered&.label&.call(record).to_s.presence || snapshot
    end

    def record
      return @record if resolution_known?

      @record = resolve
    end

    # True once the record has an answer, hit or miss, **without asking for one**. `ActorResolver`
    # reads it to skip refs a caller has already resolved.
    def resolution_known?
      !UNRESOLVED.equal?(@record)
    end

    # `ActorResolver`'s seam: a page resolves every ref in one query per actor type and hands each
    # one its answer, so nothing resolves itself (§11).
    def resolve_with(record)
      @record = record

      self
    end

    def resolved?
      !record.nil?
    end

    def deleted?
      !resolved?
    end

    # Nil whenever there is no record or the type declares no `path` lambda - which includes every
    # headless caller, since `routes` is the host's url helpers and a job has none (§11).
    def path(routes)
      return nil if routes.nil? || !resolved?

      registered&.path&.call(record, routes)
    end

    # The stored triple, exactly as the reader returned it before this class existed. `label` here
    # is the **snapshot**, not the resolved one: this is the row, and reading a row should not
    # query. `#label` is the resolved view.
    def to_h
      { type: type, id: id }.merge(@columns)
    end

    def ==(other)
      other.is_a?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    private

    def live_labels?
      ChangeRequests.config.actor_label_strategy == :live
    end

    def registered
      ChangeRequests.registered_type(type)
    end

    # Degrades, never raises (§11). An unregistered type, a class the application no longer defines,
    # and an id that will not cast to the column's type all resolve to nothing - a page rendering a
    # five-year-old request must not blow up because someone deleted a model.
    #
    # It goes through the same `cast_id` and `finder` the batch resolver uses, so resolving one ref
    # and resolving a page of them cannot disagree about what a type's records are.
    def resolve
      return nil if registered.nil?

      cast = registered.cast_id(id)

      return nil if cast.nil?

      Array(registered.finder.call([cast])).first
    end
  end
end
