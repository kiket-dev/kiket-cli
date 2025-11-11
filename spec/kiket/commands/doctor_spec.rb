# frozen_string_literal: true

require "spec_helper"
require "kiket/commands/doctor"

RSpec.describe Kiket::Commands::Doctor do
  let(:config) { test_config(default_org: "org-1") }
  let(:client) { instance_double(Kiket::Client) }

  before do
    Kiket.reset!
    Kiket.instance_variable_set(:@config, config)
    allow(Kiket).to receive(:client).and_return(client)
  end

  after do
    Kiket.reset!
  end

  it "fetches diagnostics when checking extensions" do
    allow(client).to receive(:get).with("/api/v1/health").and_return({})
    allow(client).to receive(:get).with("/api/v1/me").and_return({ "email" => "ops@kiket.dev" })
    allow(client).to receive(:get).with("/api/v1/organizations/org-1").and_return({ "name" => "Acme" })
    allow(client).to receive(:get).with("/api/v1/extensions", params: hash_including(organization: "org-1"))
                                  .and_return({ "extensions" => [] })
    allow(client).to receive(:get).with("/api/v1/secrets/health", params: hash_including(organization: "org-1"))
                                  .and_return({ "secret_count" => 0, "expiring_soon" => [], "invalid" => [] })

    expect(client).to receive(:get)
      .with("/api/v1/diagnostics", params: hash_including(organization_id: "org-1"))
      .and_return({
        "extensions" => [
          {
            "extension_id" => "dev.test",
            "extension_name" => "Diag",
            "status" => "failed",
            "error" => "401",
            "recommendation" => "Reset token"
          }
        ],
        "definitions" => []
      })

    expect { described_class.start([ "run", "--extensions" ]) }.to output(/Reset token/).to_stdout
  end
end
