# frozen_string_literal: true

require "spec_helper"
require "kiket/commands/marketplace"
require "tempfile"
require "yaml"

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
        when %r{\A/api/v1/marketplace/installations/\d+/secrets\z}
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

      expect(post_calls.map(&:first)).to include("/api/v1/marketplace/installations/123/secrets")
    end
  end

  describe "#telemetry report" do
    it "renders telemetry summary" do
      summary = {
        "window_seconds" => 86_400,
        "total_events" => 10,
        "error_count" => 2,
        "error_rate" => 20.0,
        "avg_latency_ms" => 120.5,
        "p95_latency_ms" => 250,
        "top_extensions" => [
          {
            "name" => "Make.com",
            "extension_id" => "com.example.make",
            "total" => 6,
            "error_rate" => 10.0,
            "avg_latency_ms" => 110.0
          }
        ],
        "recent_errors" => [
          {
            "name" => "Make.com",
            "extension_id" => "com.example.make",
            "event" => "workflow.before_transition",
            "error_message" => "Timeout",
            "occurred_at" => "2025-11-09T10:00:00Z"
          }
        ]
      }

      expect(client).to receive(:get)
        .with("/api/v1/marketplace/telemetry", params: {})
        .and_return(summary)

      output = capture_stdout do
        described_class.start(%w[telemetry report])
      end

      expect(output).to include("Marketplace Telemetry")
      expect(output).to include("Requests: 10")
      expect(output).to include("Make.com")
    end
  end

  describe "#dbt" do
    it "renders installation dbt runs" do
      runs = {
        "runs" => [
          {
            "id" => 42,
            "status" => "success",
            "command" => "run",
            "queued_at" => "2025-11-10T10:00:00Z",
            "duration_ms" => 15000,
            "message" => "dbt run completed"
          }
        ]
      }

      expect(client).to receive(:get)
        .with("/api/v1/marketplace/installations/123/dbt_runs", params: { limit: 10 })
        .and_return(runs)

      output = capture_stdout do
        described_class.start(%w[dbt 123])
      end

      expect(output).to include("42")
      expect(output).to include("success")
      expect(output).to include("dbt run completed")
    end
  end

  describe "#onboarding_wizard" do
    it "creates a blueprint scaffold from the template" do
      Dir.mktmpdir do |dir|
        destination = File.join(dir, "custom-blueprint")

        described_class.start([
                                 "onboarding_wizard",
                                 "--identifier", "custom-blueprint",
                                 "--name", "Custom Blueprint",
                                 "--description", "Demo product",
                                 "--destination", destination,
                                 "--template", "sample",
                                 "--force"
                               ])

        manifest_path = File.join(destination, ".kiket", "manifest.yaml")
        expect(File).to exist(manifest_path)
        manifest = YAML.safe_load(File.read(manifest_path))
        expect(manifest["identifier"]).to eq("custom-blueprint")
        expect(manifest["name"]).to eq("Custom Blueprint")
      end
    end
  end

  describe "#metadata" do
    it "writes product manifest and blueprint config" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p("definitions/demo/.kiket")
          FileUtils.mkdir_p("config/marketplace/blueprints")

          described_class.start([
                                   "metadata",
                                   "definitions/demo",
                                   "--identifier", "demo-kit",
                                   "--name", "Demo Kit",
                                   "--categories", "ops",
                                   "--pricing-model", "team"
                                 ])

          manifest_path = File.join("definitions/demo/.kiket", "product.yaml")
          expect(File).to exist(manifest_path)
          manifest = YAML.safe_load(File.read(manifest_path))
          expect(manifest["identifier"]).to eq("demo-kit")
          expect(manifest.dig("metadata", "categories")).to eq(["ops"])

          blueprint_path = File.join("config/marketplace/blueprints", "demo_kit.yml")
          expect(File).to exist(blueprint_path)
        end
      end
    end
  end

  describe "#import" do
    it "copies assets and regenerates metadata" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          source = File.join(dir, "partner-kit")
          FileUtils.mkdir_p(File.join(source, ".kiket"))
          File.write(File.join(source, "README.md"), "# Partner Kit")
          File.write(
            File.join(source, ".kiket", "product.yaml"),
            {
              "identifier" => "sample-kit",
              "name" => "Sample Kit",
              "version" => "1.2.3",
              "metadata" => {
                "pricing" => { "model" => "custom" }
              }
            }.to_yaml
          )

          FileUtils.mkdir_p("config/marketplace/blueprints")

          described_class.start(["import", source])

          destination = File.join("definitions", "sample-kit")
          expect(File).to exist(File.join(destination, "README.md"))
          manifest_path = File.join(destination, ".kiket", "product.yaml")
          expect(File).to exist(manifest_path)
          config_path = File.join("config/marketplace/blueprints", "sample_kit.yml")
          expect(File).to exist(config_path)
        end
      end
    end
  end

  describe "#sync_samples" do
    it "copies the requested blueprint directories" do
      Dir.mktmpdir do |dir|
        described_class.start([
                                 "sync_samples",
                                 "--destination", dir,
                                 "--blueprints", "sample",
                                 "--force"
                               ])

        definition_dir = File.join(dir, "sample", ".kiket")
        expect(Dir).to exist(definition_dir)
        expect(File).to exist(File.join(definition_dir, "product.yaml"))
      end
    end
  end

  def capture_stdout
    original = $stdout
    fake = StringIO.new
    $stdout = fake
    yield
    fake.string
  ensure
    $stdout = original
  end
end
