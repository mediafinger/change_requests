# frozen_string_literal: true

# `ChangeRequests.config` and `ChangeRequests.operations` are memoised module state, so a
# registration made in one example is visible in every example that runs after it. Every example
# gets its own copy of both; the originals - whatever spec/dummy registered at boot - go back
# afterwards, so the copies never accumulate.
#
# Written against the ivars rather than through a writer: the gem's public surface is `config` and
# `operations`, and swapping them out is a test concern, not a host one.
module GlobalState
  MEMOS = { :@config => :config, :@operations => :operations }.freeze

  def self.snapshot
    MEMOS.to_h { |ivar, reader| [ivar, ChangeRequests.public_send(reader)] }
  end

  def self.install(memos)
    memos.each { |ivar, value| ChangeRequests.instance_variable_set(ivar, value) }
  end

  def self.copies(memos)
    memos.transform_values(&:dup)
  end
end

RSpec.configure do |config|
  config.around do |example|
    original = GlobalState.snapshot
    GlobalState.install(GlobalState.copies(original))

    example.run
  ensure
    GlobalState.install(original)
  end
end
