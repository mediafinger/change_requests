# frozen_string_literal: true

# Out of process: this suite loads the dummy app, so Rails is defined here whatever the gem does.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "the domain core, headless" do
  subject(:probe) { ruby_script("spec/integration/headless_script.rb") }

  it "never loads Rails" do
    expect(probe).to include("rails=absent")
    expect(probe).to include("action_controller=absent")
  end

  it "still has no Rails by the time it finishes, in case something pulled it in on the way" do
    expect(probe).to include("rails_at_exit=absent")
  end

  it "defines no engine" do
    expect(probe).to include("engine=absent")
  end

  it "eager loads, so a misfiled constant fails here rather than in a host application" do
    expect(probe).to include("eager_load=ok")
  end

  it "derives table names without an engine to install the prefix" do
    expect(probe).to include("table_name_prefix=change_request_")
  end

  it "configures and validates itself" do
    expect(probe).to include("validate=true")
  end

  it "produces an error message with no I18n and no locale files" do
    expect(probe).to include("error_message=requester")
  end

  it "talks to PostgreSQL over a bare ActiveRecord connection" do
    expect(probe).to include("adapter=PostgreSQL")
    expect(probe).to include("query=1")
  end
end
