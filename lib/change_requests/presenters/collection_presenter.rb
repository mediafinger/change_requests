# frozen_string_literal: true

module ChangeRequests
  # A page of requests, presented (§11).
  #
  #   CollectionPresenter.new(Request.visible_to(current_user).page(1), actor: current_user, routes: view)
  #
  # Owns eager loading, so the N+1 is fixed once rather than in every view: it preloads every association
  # a RequestPresenter reads, then resolves every actor on the page in one query per actor type and hands
  # each presenter its refs already answered. Actions are not preloaded - each guard asks its own questions.
  class CollectionPresenter
    include Enumerable

    attr_reader :actor, :routes

    def initialize(requests, actor:, routes: nil, resolve_actors: true)
      @requests       = requests
      @actor          = actor
      @routes         = routes
      @resolve_actors = resolve_actors
    end

    def resolve_actors?
      @resolve_actors
    end

    def each(&)
      presenters.each(&)
    end

    def size
      presenters.size
    end

    def presenters
      @presenters ||= begin
        records = @requests.to_a
        ActiveRecord::Associations::Preloader.new(records: records, associations: RequestPresenter::PRELOAD).call

        built = records.map do |request|
          RequestPresenter.new(request, actor: actor, routes: routes, resolve_actors: resolve_actors?)
        end

        ActorResolver.call(built.flat_map(&:actor_refs)) if resolve_actors?

        built
      end
    end
  end
end
