# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "kiket/commands/agents"

RSpec.describe Kiket::Commands::Agents do
  let(:config) { test_config(output_format: "human") }
  let(:client) { instance_double(Kiket::Client) }

  before do
    Kiket.reset!
    Kiket.instance_variable_set(:@config, config)
    allow(Kiket).to receive(:client).and_return(client)
  end

  after do
    Kiket.reset!
  end

  describe "#list" do
    it "prints agent catalog" do
      response = {
        "project" => { "id" => 99, "name" => "Ops" },
        "agents" => [
          {
            "id" => "triage.coach",
            "name" => "Triage Coach",
            "capabilities" => %w[triage summarize],
            "inputs" => [
              { "name" => "incident", "type" => "Issue" }
            ],
            "outputs" => [
              { "name" => "plan", "type" => "Markdown" }
            ]
          }
        ]
      }

      expect(client).to receive(:get).with("/api/v1/projects/99/agents", params: { organization: "test-org" })
                                     .and_return(response)

      output = capture_stdout do
        described_class.start(%w[list 99])
      end

      expect(output).to include("triage.coach")
      expect(output).to include("Issue")
      expect(output).to include("triage, summarize")
    end
  end

  def capture_stdout
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    yield
    buffer.string
  ensure
    $stdout = original
  end
end
