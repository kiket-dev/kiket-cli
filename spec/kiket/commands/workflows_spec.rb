# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "kiket/commands/workflows"

RSpec.describe Kiket::Commands::Workflows do
  let(:config) { test_config(output_format: "human") }

  before do
    Kiket.reset!
    Kiket.instance_variable_set(:@config, config)
  end

  after { Kiket.reset! }

  describe "lint" do
    def lint_yaml(yaml_content)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "workflow.yaml"), yaml_content)
        output = capture_stdout do
          begin
            described_class.start(["lint", dir])
          rescue SystemExit
            # lint exits 1 on errors
          end
        end
        output
      end
    end

    it "passes for a valid workflow" do
      yaml = <<~YAML
        model_version: "1.0"
        workflow:
          id: test
          name: Test Workflow
          description: A test workflow
        states:
          open:
            type: initial
            category: pending
            metadata:
              label: Open
              color: primary
              icon: ""
          done:
            type: final
            category: completed
            metadata:
              label: Done
              color: success
              icon: ""
        transitions:
          - from: open
            to: done
            name: Complete
      YAML

      output = lint_yaml(yaml)
      expect(output).to include("Workflow validation complete")
    end

    it "warns on missing initial state" do
      yaml = <<~YAML
        model_version: "1.0"
        workflow:
          id: test
          name: Test
        states:
          review:
            type: active
            category: active
            metadata: { label: Review, color: primary, icon: "" }
      YAML

      output = lint_yaml(yaml)
      expect(output).to include("No initial or trigger state")
    end

    it "validates SLA duration format" do
      yaml = <<~YAML
        model_version: "1.0"
        workflow:
          id: test
          name: Test
        states:
          review:
            type: initial
            category: active
            metadata: { label: Review, color: primary, icon: "" }
            sla:
              warning: "bad_format"
              breach: 48h
      YAML

      output = lint_yaml(yaml)
      expect(output).to include("invalid")
      expect(output).to include("bad_format")
    end

    it "accepts valid SLA durations" do
      yaml = <<~YAML
        model_version: "1.0"
        workflow:
          id: test
          name: Test
          description: Test
        states:
          open:
            type: initial
            category: pending
            metadata: { label: Open, color: primary, icon: "" }
            sla:
              warning: 24h
              breach: 7d
              business_hours: true
          done:
            type: final
            category: completed
            metadata: { label: Done, color: success, icon: "" }
        transitions:
          - from: open
            to: done
            name: Complete
      YAML

      output = lint_yaml(yaml)
      expect(output).to include("Workflow validation complete")
    end

    it "validates lifecycle hook action types" do
      yaml = <<~YAML
        model_version: "1.0"
        workflow:
          id: test
          name: Test
        states:
          review:
            type: initial
            category: active
            metadata: { label: Review, color: primary, icon: "" }
            on_enter:
              - action: invalid_action_type
      YAML

      output = lint_yaml(yaml)
      expect(output).to include("unknown action")
    end

    it "validates transition conditions" do
      yaml = <<~YAML
        model_version: "1.0"
        workflow:
          id: test
          name: Test
        states:
          open:
            type: initial
            category: pending
            metadata: { label: Open, color: primary, icon: "" }
          done:
            type: final
            category: completed
            metadata: { label: Done, color: success, icon: "" }
        transitions:
          - from: open
            to: done
            name: Complete
            conditions:
              - field: priority
                operator: invalid_op
      YAML

      output = lint_yaml(yaml)
      expect(output).to include("unknown operator")
    end

    it "warns on spawn_issue without template" do
      yaml = <<~YAML
        model_version: "1.0"
        workflow:
          id: test
          name: Test
        states:
          review:
            type: initial
            category: active
            metadata: { label: Review, color: primary, icon: "" }
            on_enter:
              - action: spawn_issue
      YAML

      output = lint_yaml(yaml)
      expect(output).to include("spawn_issue missing metadata.template")
    end
  end
end
