# frozen_string_literal: true

require "spec_helper"
require "kiket/commands/marketplace"
require "tempfile"

RSpec.describe Kiket::Commands::Marketplace do
  let(:config) { test_config }
  let(:client) { instance_double(Kiket::Client) }
  let(:spinner) { instance_double(TTY::Spinner, auto_spin: true, success: true) }

  before do
    Kiket.reset!
    Kiket.instance_variable_set(:@config, config)
    allow(Kiket).to receive(:client).and_return(client)
    allow(TTY::Spinner).to receive(:new).and_return(spinner)
  end

  after do
    Kiket.reset!
  end

  describe "#install" do
    it "uploads missing extension secrets from env file and refreshes installation" do
      product = { "product" => { "id" => "blueprint-1", "name" => "Blueprint", "version" => "1.0.0",
                                 "description" => "Test blueprint", "pricing_model" => "team" } }
      installation = {
        "installation" => {
          "id" => 123,
          "status" => "installing",
          "extensions" => [
            {
              "extension_id" => "com.example.required",
              "name" => "Required Extension",
              "required" => true,
              "present" => true,
              "secrets" => [{ "key" => "REQUIRED_TOKEN", "description" => "API token" }]
            }
          ],
          "missing_extension_secrets" => { "com.example.required" => ["REQUIRED_TOKEN"] },
          "scaffolded_extension_secrets" => {}
        }
      }
      refreshed = {
        "installation" => installation["installation"].merge(
          "missing_extension_secrets" => {},
          "extensions" => [
            installation["installation"]["extensions"].first.merge(
              "missing_secrets" => [],
              "scaffolded_secrets" => []
            )
          ]
        )
      }

      allow(client).to receive(:get).with("/api/v1/marketplace/products/blueprint-1").and_return(product)

      post_calls = []
      allow(client).to receive(:post) do |path, payload|
        post_calls << [path, payload]
        case path
        when "/api/v1/marketplace/installations"
          installation
        when %r{\A/api/v1/extensions/.+/secrets\z}
          {}
        when "/api/v1/marketplace/installations/123/refresh"
          refreshed
        else
          {}
        end
      end
      allow(client).to receive(:patch).and_return({})

      env_file = Tempfile.new("secrets.env")
      begin
        env_file.write("REQUIRED_TOKEN=secret-value\n")
        env_file.flush

        described_class.start(["install", "blueprint-1", "--env-file", env_file.path, "--non-interactive"])
      ensure
        env_file.close
        env_file.unlink
      end

      expect(post_calls.map(&:first)).to include("/api/v1/extensions/com.example.required/secrets")
    end
  end
end
