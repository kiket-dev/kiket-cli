# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "kiket/commands/milestones"

RSpec.describe Kiket::Commands::Milestones do
  let(:config) { test_config(output_format: "human") }
  let(:client) { instance_double(Kiket::Client) }
  let(:spinner_double) { instance_double(TTY::Spinner, auto_spin: true, success: true) }
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

  describe "milestones list" do
    let(:milestones_response) do
      {
        "milestones" => [
          {
            "id" => 1,
            "name" => "Q1 Release",
            "status" => "active",
            "progress" => 45,
            "target_date" => "2026-03-31",
            "issue_count" => 10,
            "completed_issue_count" => 4,
            "days_remaining" => 109,
            "overdue" => false
          },
          {
            "id" => 2,
            "name" => "Q2 Release",
            "status" => "planning",
            "progress" => 0,
            "target_date" => "2026-06-30",
            "issue_count" => 0,
            "completed_issue_count" => 0,
            "days_remaining" => 200,
            "overdue" => false
          }
        ]
      }
    end

    it "lists milestones for a project" do
      expect(client).to receive(:get).with(
        "/api/v1/projects/20/milestones",
        params: {}
      ).and_return(milestones_response)

      output = capture_stdout do
        described_class.start(%w[list 20])
      end

      expect(output).to include("Q1 Release")
      expect(output).to include("Q2 Release")
      expect(output).to include("45%")
      expect(output).to include("4/10")
    end

    it "filters by status" do
      expect(client).to receive(:get).with(
        "/api/v1/projects/20/milestones",
        params: { status: "active" }
      ).and_return({ "milestones" => [milestones_response["milestones"].first] })

      output = capture_stdout do
        described_class.start(%w[list 20 --status active])
      end

      expect(output).to include("Q1 Release")
      expect(output).not_to include("Q2 Release")
    end

    it "shows warning when no milestones found" do
      expect(client).to receive(:get).and_return({ "milestones" => [] })

      output = capture_stdout do
        described_class.start(%w[list 20])
      end

      expect(output).to include("No milestones found")
    end
  end

  describe "milestones show" do
    let(:milestone_response) do
      {
        "milestone" => {
          "id" => 1,
          "name" => "Q1 Release",
          "description" => "First quarter release with major features",
          "status" => "active",
          "progress" => 45,
          "target_date" => "2026-03-31",
          "version" => "v1.0.0",
          "issue_count" => 10,
          "completed_issue_count" => 4,
          "days_remaining" => 109,
          "overdue" => false,
          "created_at" => "2025-12-01T10:00:00Z",
          "updated_at" => "2025-12-12T15:00:00Z"
        }
      }
    end

    it "shows milestone details" do
      expect(client).to receive(:get).with(
        "/api/v1/projects/20/milestones/1"
      ).and_return(milestone_response)

      output = capture_stdout do
        described_class.start(%w[show 20 1])
      end

      expect(output).to include("Q1 Release")
      expect(output).to include("active")
      expect(output).to include("45%")
      expect(output).to include("v1.0.0")
      expect(output).to include("First quarter release")
      expect(output).to include("4/10 completed")
    end
  end

  describe "milestones create" do
    let(:created_milestone) do
      {
        "milestone" => {
          "id" => 5,
          "name" => "New Milestone",
          "status" => "planning",
          "progress" => 0,
          "target_date" => "2026-06-30"
        }
      }
    end

    it "creates a milestone with required fields" do
      expect(client).to receive(:post).with(
        "/api/v1/projects/20/milestones",
        body: {
          milestone: hash_including(
            name: "New Milestone",
            status: "planning"
          )
        }
      ).and_return(created_milestone)

      output = capture_stdout do
        described_class.start(["create", "20", "--name", "New Milestone"])
      end

      expect(output).to include("Created milestone")
      expect(output).to include("New Milestone")
      expect(output).to include("ID: 5")
    end

    it "creates a milestone with all options" do
      expect(client).to receive(:post).with(
        "/api/v1/projects/20/milestones",
        body: {
          milestone: {
            name: "Full Milestone",
            description: "A complete milestone",
            target_date: "2026-06-30",
            status: "active",
            version: "v2.0.0"
          }
        }
      ).and_return({
                     "milestone" => {
                       "id" => 6,
                       "name" => "Full Milestone",
                       "status" => "active",
                       "target_date" => "2026-06-30"
                     }
                   })

      output = capture_stdout do
        described_class.start([
                                "create", "20",
                                "--name", "Full Milestone",
                                "--description", "A complete milestone",
                                "--target-date", "2026-06-30",
                                "--status", "active",
                                "--version", "v2.0.0"
                              ])
      end

      expect(output).to include("Created milestone")
      expect(output).to include("Full Milestone")
    end
  end

  describe "milestones update" do
    let(:updated_milestone) do
      {
        "milestone" => {
          "id" => 1,
          "name" => "Updated Name",
          "status" => "active",
          "progress" => 50
        }
      }
    end

    it "updates milestone name" do
      expect(client).to receive(:patch).with(
        "/api/v1/projects/20/milestones/1",
        body: {
          milestone: { name: "Updated Name" }
        }
      ).and_return(updated_milestone)

      output = capture_stdout do
        described_class.start(["update", "20", "1", "--name", "Updated Name"])
      end

      expect(output).to include("Updated milestone")
      expect(output).to include("Updated Name")
    end

    it "updates milestone status" do
      expect(client).to receive(:patch).with(
        "/api/v1/projects/20/milestones/1",
        body: {
          milestone: { status: "completed" }
        }
      ).and_return({
                     "milestone" => {
                       "id" => 1,
                       "name" => "Q1 Release",
                       "status" => "completed",
                       "progress" => 100
                     }
                   })

      output = capture_stdout do
        described_class.start(%w[update 20 1 --status completed])
      end

      expect(output).to include("Updated milestone")
      expect(output).to include("completed")
    end

    it "errors when no updates provided" do
      output = capture_stdout do
        expect { described_class.start(%w[update 20 1]) }.to raise_error(SystemExit)
      end

      expect(output).to include("No updates provided")
    end
  end

  describe "milestones delete" do
    it "deletes milestone with force flag" do
      expect(client).to receive(:delete).with(
        "/api/v1/projects/20/milestones/1"
      )

      output = capture_stdout do
        described_class.start(%w[delete 20 1 --force])
      end

      expect(output).to include("Milestone 1 has been deleted")
    end

    it "prompts for confirmation without force flag" do
      expect(client).to receive(:get).with(
        "/api/v1/projects/20/milestones/1"
      ).and_return({ "milestone" => { "id" => 1, "name" => "Q1 Release" } })

      expect(prompt_double).to receive(:yes?).with(/Delete milestone/).and_return(true)
      expect(client).to receive(:delete).with("/api/v1/projects/20/milestones/1")

      output = capture_stdout do
        described_class.start(%w[delete 20 1])
      end

      expect(output).to include("deleted")
    end

    it "cancels deletion when user declines" do
      expect(client).to receive(:get).with(
        "/api/v1/projects/20/milestones/1"
      ).and_return({ "milestone" => { "id" => 1, "name" => "Q1 Release" } })

      expect(prompt_double).to receive(:yes?).and_return(false)

      output = capture_stdout do
        described_class.start(%w[delete 20 1])
      end

      expect(output).to include("Cancelled")
    end
  end

  describe "JSON output format" do
    let(:json_config) { test_config(output_format: "json") }

    before do
      Kiket.instance_variable_set(:@config, json_config)
    end

    it "outputs milestones as JSON" do
      milestones = [{ "id" => 1, "name" => "Test" }]
      expect(client).to receive(:get).and_return({ "milestones" => milestones })

      output = capture_stdout do
        described_class.start(%w[list 20])
      end

      parsed = MultiJson.load(output)
      expect(parsed).to be_an(Array)
      expect(parsed.first["name"]).to eq("Test")
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
