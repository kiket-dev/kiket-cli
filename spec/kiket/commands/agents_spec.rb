# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"
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

  describe "#lint" do
    it "validates a valid agent manifest" do
      Dir.mktmpdir do |dir|
        agents_dir = File.join(dir, ".kiket", "agents")
        FileUtils.mkdir_p(agents_dir)

        manifest = <<~YAML
          model_version: "1.0"
          id: test.agent
          version: 1.0.0
          name: Test Agent
          description: A test agent
          prompt: Analyze the issue
          capabilities:
            - summarize
            - classify
        YAML

        File.write(File.join(agents_dir, "test_agent.yaml"), manifest)

        output = capture_stdout do
          expect { described_class.start(["lint", dir]) }.not_to raise_error
        end

        expect(output).to include("Valid: 1")
        expect(output).to include("Agent manifest validation complete")
      end
    end

    it "reports errors for missing required fields" do
      Dir.mktmpdir do |dir|
        agents_dir = File.join(dir, ".kiket", "agents")
        FileUtils.mkdir_p(agents_dir)

        manifest = <<~YAML
          model_version: "1.0"
          name: Incomplete Agent
        YAML

        File.write(File.join(agents_dir, "incomplete.yaml"), manifest)

        output = capture_stdout do
          expect { described_class.start(["lint", dir]) }.to raise_error(SystemExit)
        end

        expect(output).to include("Missing required field 'id'")
        expect(output).to include("Missing required field 'version'")
        expect(output).to include("Missing required field 'prompt'")
        expect(output).to include("Missing or empty 'capabilities'")
      end
    end

    it "reports errors for invalid id format" do
      Dir.mktmpdir do |dir|
        agents_dir = File.join(dir, ".kiket", "agents")
        FileUtils.mkdir_p(agents_dir)

        manifest = <<~YAML
          model_version: "1.0"
          id: Invalid Agent ID
          version: 1.0.0
          name: Test Agent
          prompt: Analyze
          capabilities:
            - test
        YAML

        File.write(File.join(agents_dir, "invalid_id.yaml"), manifest)

        output = capture_stdout do
          expect { described_class.start(["lint", dir]) }.to raise_error(SystemExit)
        end

        expect(output).to include("Invalid id format")
      end
    end

    it "reports errors for invalid human_in_loop keys" do
      Dir.mktmpdir do |dir|
        agents_dir = File.join(dir, ".kiket", "agents")
        FileUtils.mkdir_p(agents_dir)

        manifest = <<~YAML
          model_version: "1.0"
          id: test.agent
          version: 1.0.0
          name: Test Agent
          prompt: Analyze
          capabilities:
            - test
          human_in_loop:
            required: true
            invalid_key: value
        YAML

        File.write(File.join(agents_dir, "invalid_hil.yaml"), manifest)

        output = capture_stdout do
          expect { described_class.start(["lint", dir]) }.to raise_error(SystemExit)
        end

        expect(output).to include("human_in_loop' contains unknown keys: invalid_key")
      end
    end

    it "accepts valid human_in_loop with reason key" do
      Dir.mktmpdir do |dir|
        agents_dir = File.join(dir, ".kiket", "agents")
        FileUtils.mkdir_p(agents_dir)

        manifest = <<~YAML
          model_version: "1.0"
          id: test.agent
          version: 1.0.0
          name: Test Agent
          description: Test
          prompt: Analyze
          capabilities:
            - test
          human_in_loop:
            required: true
            reason: Requires human review
        YAML

        File.write(File.join(agents_dir, "valid_hil.yaml"), manifest)

        output = capture_stdout do
          expect { described_class.start(["lint", dir]) }.not_to raise_error
        end

        expect(output).to include("Valid: 1")
      end
    end

    it "warns when no agent files are found" do
      Dir.mktmpdir do |dir|
        output = capture_stdout do
          described_class.start(["lint", dir])
        rescue SystemExit => e
          expect(e.status).to eq(0)
        end

        expect(output).to include("No agent manifest files found")
      end
    end
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
