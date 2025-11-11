# frozen_string_literal: true

require "spec_helper"
require "kiket/commands/sla"

RSpec.describe Kiket::Commands::Sla do
  let(:config) { test_config(default_org: "acme") }
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

  describe "#events" do
    it "fetches events and prints output" do
      response = {
        "data" => [
          {
            "id" => 1,
            "issue_id" => 42,
            "project_id" => 7,
            "state" => "imminent",
            "definition" => {
              "status" => "in_progress",
              "max_duration_minutes" => 90
            },
            "metrics" => {
              "duration_minutes" => 80
            }
          }
        ]
      }

      expect(client).to receive(:get)
        .with("/api/v1/sla_events", params: hash_including(organization: "acme"))
        .and_return(response)

      expect do
        described_class.start([ "events" ])
      end.not_to raise_error
    end
  end
end
