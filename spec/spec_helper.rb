# frozen_string_literal: true

require "bundler/setup"
require "kiket"
require "webmock/rspec"
require "vcr"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!
  config.warnings = true

  config.default_formatter = "doc" if config.files_to_run.one?

  config.profile_examples = 10
  config.order = :random

  Kernel.srand config.seed
end

# VCR configuration for recording HTTP interactions
VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.filter_sensitive_data("<API_TOKEN>") { ENV["KIKET_API_TOKEN"] }
  config.filter_sensitive_data("<API_URL>") { ENV["KIKET_API_URL"] }
end

# Helper to create a test config
def test_config(overrides = {})
  Kiket::Config.new({
    api_base_url: "https://test.kiket.ai",
    api_token: "test-token",
    default_org: "test-org",
    output_format: "json",
    verbose: false
  }.merge(overrides))
end

# Helper to stub API requests
def stub_api_request(method, path, response: {}, status: 200, headers: {})
  stub_request(method, "https://test.kiket.ai#{path}")
    .to_return(
      status: status,
      body: response.to_json,
      headers: { "Content-Type" => "application/json" }.merge(headers)
    )
end
