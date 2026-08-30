# frozen_string_literal: true

require "yaml"

require "edge"
require "webmock/rspec"

# Nothing in this suite may reach the network. A client that silently talks to
# a real gateway during tests is a bug in the suite, not a convenience.
WebMock.disable_net_connect!(allow_localhost: false)

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.warnings = true
  # Declaring a contract registers the class, so that a relationship pointing
  # at a resource resolves to it. Examples that define throwaway resource
  # classes would otherwise leave them in that registry for every later
  # example, and the order is random.
  config.around do |example|
    snapshot = Edge::Resource.registry.dup
    example.run
    Edge::Resource.registry.replace(snapshot)
  end

  # Needs a server and a credential, and the rest of the suite may not touch
  # the network at all. Run it with `--tag live` and the EDGE_LIVE_* variables
  # spec/contract/live_spec.rb documents.
  config.filter_run_excluding :live
  config.before(:each, :live) { WebMock.allow_net_connect! }
  config.after(:each, :live) { WebMock.disable_net_connect!(allow_localhost: false) }

  config.order = :random
  Kernel.srand config.seed
end
