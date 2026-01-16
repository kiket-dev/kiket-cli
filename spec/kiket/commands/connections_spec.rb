# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "kiket/commands/connections"

RSpec.describe Kiket::Commands::Connections do
  let(:config) { test_config(output_format: "human") }
  let(:client) { instance_double(Kiket::Client) }
  let(:spinner_double) { instance_double(TTY::Spinner, auto_spin: true, success: true, stop: true) }
  let(:prompt_double) { instance_double(TTY::Prompt) }

  before do
    Kiket.reset!
    Kiket.instance_variable_set(:@config, config)
    allow(Kiket).to receive(:client).and_return(client)
    allow(TTY::Spinner).to receive(:new).and_return(spinner_double)
    allow(TTY::Prompt).to receive(:new).and_return(prompt_double)
  end

  after do
    Kiket.reset!
  end

  describe "connections list" do
    let(:connections_response) do
      {
        "connections" => [
          {
            "id" => 1,
            "provider_id" => "google-oauth",
            "provider_name" => "Google",
            "status" => "active",
            "external_email" => "user@gmail.com",
            "connected_at" => "2026-01-01T10:00:00Z",
            "consumer_extensions" => [
              { "id" => "google-calendar", "name" => "Google Calendar" }
            ]
          },
          {
            "id" => 2,
            "provider_id" => "microsoft-oauth",
            "provider_name" => "Microsoft",
            "status" => "expired",
            "external_email" => "user@outlook.com",
            "connected_at" => "2025-12-01T10:00:00Z",
            "consumer_extensions" => []
          }
        ]
      }
    end

    it "lists all OAuth connections" do
      expect(client).to receive(:get).with(
        "/api/v1/oauth/connections",
        params: {}
      ).and_return(connections_response)

      output = capture_stdout do
        described_class.start(%w[list])
      end

      expect(output).to include("Google")
      expect(output).to include("Microsoft")
      expect(output).to include("user@gmail.com")
      expect(output).to include("active")
      expect(output).to include("expired")
    end

    it "filters by status" do
      expect(client).to receive(:get).with(
        "/api/v1/oauth/connections",
        params: { status: "active" }
      ).and_return({ "connections" => [connections_response["connections"].first] })

      output = capture_stdout do
        described_class.start(%w[list --status active])
      end

      expect(output).to include("Google")
      expect(output).not_to include("Microsoft")
    end

    it "shows helpful message when no connections found" do
      expect(client).to receive(:get).and_return({ "connections" => [] })

      output = capture_stdout do
        described_class.start(%w[list])
      end

      expect(output).to include("No OAuth connections found")
    end
  end

  describe "connections show" do
    let(:connection_response) do
      {
        "connection" => {
          "id" => 1,
          "provider_id" => "google-oauth",
          "provider_name" => "Google",
          "status" => "active",
          "external_email" => "user@gmail.com",
          "connected_at" => "2026-01-01T10:00:00Z",
          "expires_at" => "2026-02-01T10:00:00Z",
          "granted_scopes" => %w[email profile calendar.readonly],
          "consumer_extensions" => [
            { "id" => "google-calendar", "name" => "Google Calendar" }
          ]
        }
      }
    end

    it "shows connection details" do
      expect(client).to receive(:get).with(
        "/api/v1/oauth/connections/1"
      ).and_return(connection_response)

      output = capture_stdout do
        described_class.start(%w[show 1])
      end

      expect(output).to include("Google")
      expect(output).to include("user@gmail.com")
      expect(output).to include("active")
      expect(output).to include("email")
      expect(output).to include("calendar.readonly")
      expect(output).to include("Google Calendar")
    end
  end

  describe "connections disconnect" do
    let(:connection_response) do
      {
        "connection" => {
          "id" => 1,
          "provider_id" => "google-oauth",
          "provider_name" => "Google",
          "status" => "active",
          "external_email" => "user@gmail.com",
          "consumer_extensions" => [
            { "id" => "google-calendar", "name" => "Google Calendar" }
          ]
        }
      }
    end

    it "disconnects with force flag" do
      expect(client).to receive(:get).with(
        "/api/v1/oauth/connections/1"
      ).and_return(connection_response)

      expect(client).to receive(:post).with(
        "/api/v1/oauth/connections/1/disconnect"
      )

      output = capture_stdout do
        described_class.start(%w[disconnect 1 --force])
      end

      expect(output).to include("disconnected")
    end

    it "prompts for confirmation without force flag" do
      expect(client).to receive(:get).with(
        "/api/v1/oauth/connections/1"
      ).and_return(connection_response)

      expect(prompt_double).to receive(:yes?).with(/Are you sure/).and_return(true)
      expect(client).to receive(:post).with("/api/v1/oauth/connections/1/disconnect")

      output = capture_stdout do
        described_class.start(%w[disconnect 1])
      end

      expect(output).to include("disconnected")
    end

    it "shows warning about affected extensions" do
      expect(client).to receive(:get).and_return(connection_response)
      expect(prompt_double).to receive(:yes?).and_return(false)

      output = capture_stdout do
        described_class.start(%w[disconnect 1])
      end

      expect(output).to include("Google Calendar")
      expect(output).to include("affect")
    end
  end

  describe "connections refresh" do
    it "refreshes connection token" do
      expect(client).to receive(:post).with(
        "/api/v1/oauth/connections/1/refresh"
      ).and_return({
                     "connection" => {
                       "id" => 1,
                       "status" => "active",
                       "expires_at" => "2026-03-01T10:00:00Z"
                     }
                   })

      output = capture_stdout do
        described_class.start(%w[refresh 1])
      end

      expect(output).to include("refreshed")
    end
  end

  describe "connections providers" do
    let(:providers_response) do
      {
        "providers" => [
          {
            "id" => "google-oauth",
            "name" => "Google",
            "installed" => true,
            "connected" => true,
            "required_by" => ["google-calendar"]
          },
          {
            "id" => "microsoft-oauth",
            "name" => "Microsoft",
            "installed" => true,
            "connected" => false,
            "required_by" => []
          }
        ]
      }
    end

    it "lists OAuth providers" do
      expect(client).to receive(:get).with(
        "/api/v1/oauth/providers"
      ).and_return(providers_response)

      output = capture_stdout do
        described_class.start(%w[providers])
      end

      expect(output).to include("Google")
      expect(output).to include("Microsoft")
      expect(output).to include("google-calendar")
    end
  end

  describe "connections provider" do
    let(:provider_response) do
      {
        "provider" => {
          "id" => "google-oauth",
          "name" => "Google",
          "installed" => true,
          "connected" => true,
          "required_by" => ["google-calendar"],
          "available_scopes" => [
            { "id" => "email", "description" => "View your email address" },
            { "id" => "calendar.readonly", "description" => "View your calendars" }
          ]
        }
      }
    end

    it "shows provider details" do
      expect(client).to receive(:get).with(
        "/api/v1/oauth/providers/google-oauth"
      ).and_return(provider_response)

      output = capture_stdout do
        described_class.start(%w[provider google-oauth])
      end

      expect(output).to include("Google")
      expect(output).to include("google-oauth")
      expect(output).to include("email")
      expect(output).to include("View your email")
      expect(output).to include("google-calendar")
    end
  end

  describe "JSON output format" do
    let(:json_config) { test_config(output_format: "json") }

    before do
      Kiket.instance_variable_set(:@config, json_config)
    end

    it "outputs connections as JSON" do
      connections = [{ "id" => 1, "provider_name" => "Google" }]
      expect(client).to receive(:get).and_return({ "connections" => connections })

      output = capture_stdout do
        described_class.start(%w[list])
      end

      parsed = MultiJson.load(output)
      expect(parsed).to be_an(Array)
      expect(parsed.first["provider_name"]).to eq("Google")
    end
  end

  def capture_stdout
    original_stdout = $stdout
    fake = StringIO.new
    $stdout = fake
    yield
    fake.string
  ensure
    $stdout = original_stdout
  end
end
