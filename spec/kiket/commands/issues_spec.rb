# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "kiket/commands/issues"

RSpec.describe Kiket::Commands::Issues do
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

  describe "issues list" do
    let(:issues_response) do
      {
        "data" => [
          {
            "id" => 1,
            "key" => "PROJ-1",
            "title" => "Fix login bug",
            "status" => "in_progress",
            "issue_type" => "bug",
            "priority" => "high",
            "assignee" => { "id" => 1, "name" => "John Doe" },
            "project_key" => "PROJ"
          },
          {
            "id" => 2,
            "key" => "PROJ-2",
            "title" => "Add new feature",
            "status" => "todo",
            "issue_type" => "story",
            "priority" => "medium",
            "assignee" => nil,
            "project_key" => "PROJ"
          }
        ],
        "meta" => {
          "current_page" => 1,
          "total_pages" => 1,
          "total_count" => 2,
          "per_page" => 25
        }
      }
    end

    it "lists issues for a project" do
      expect(client).to receive(:get).with(
        "/api/v1/issues",
        params: hash_including(project_id: "20", page: 1, per_page: 25)
      ).and_return(issues_response)

      output = capture_stdout do
        described_class.start(%w[list 20])
      end

      expect(output).to include("PROJ-1")
      expect(output).to include("Fix login bug")
      expect(output).to include("John Doe")
    end

    it "filters by status" do
      expect(client).to receive(:get).with(
        "/api/v1/issues",
        params: hash_including(project_id: "20", status: "done")
      ).and_return({ "data" => [], "meta" => {} })

      output = capture_stdout do
        described_class.start(%w[list 20 --status done])
      end

      expect(output).to include("No issues found")
    end

    it "filters by issue type" do
      expect(client).to receive(:get).with(
        "/api/v1/issues",
        params: hash_including(project_id: "20", issue_type: "bug")
      ).and_return({ "data" => [issues_response["data"].first], "meta" => { "total_count" => 1 } })

      output = capture_stdout do
        described_class.start(%w[list 20 --type bug])
      end

      expect(output).to include("PROJ-1")
      expect(output).to include("bug")
    end

    it "searches in title" do
      expect(client).to receive(:get).with(
        "/api/v1/issues",
        params: hash_including(project_id: "20", search: "login")
      ).and_return({ "data" => [issues_response["data"].first], "meta" => { "total_count" => 1 } })

      output = capture_stdout do
        described_class.start(%w[list 20 --search login])
      end

      expect(output).to include("Fix login bug")
    end
  end

  describe "issues show" do
    let(:issue_response) do
      {
        "id" => 1,
        "key" => "PROJ-1",
        "title" => "Fix login bug",
        "description" => "Users cannot log in with special characters",
        "status" => "in_progress",
        "issue_type" => "bug",
        "priority" => "high",
        "assignee" => { "id" => 1, "name" => "John Doe", "email" => "john@example.com" },
        "project_key" => "PROJ",
        "labels" => %w[urgent security],
        "due_date" => "2026-01-15",
        "created_at" => "2025-12-01T10:00:00Z",
        "updated_at" => "2025-12-12T15:00:00Z"
      }
    end

    it "shows issue details" do
      expect(client).to receive(:get).with(
        "/api/v1/issues/PROJ-1"
      ).and_return(issue_response)

      output = capture_stdout do
        described_class.start(%w[show PROJ-1])
      end

      expect(output).to include("PROJ-1")
      expect(output).to include("Fix login bug")
      expect(output).to include("in_progress")
      expect(output).to include("bug")
      expect(output).to include("high")
      expect(output).to include("John Doe")
      expect(output).to include("Users cannot log in")
      expect(output).to include("urgent, security")
    end
  end

  describe "issues create" do
    let(:created_issue) do
      {
        "id" => 5,
        "key" => "PROJ-5",
        "title" => "New Issue",
        "status" => "todo",
        "issue_type" => "task",
        "priority" => "medium"
      }
    end

    it "creates an issue with required fields" do
      expect(client).to receive(:post).with(
        "/api/v1/issues",
        body: {
          issue: hash_including(
            project_id: "20",
            title: "New Issue",
            issue_type: "task",
            priority: "medium"
          )
        }
      ).and_return(created_issue)

      output = capture_stdout do
        described_class.start(["create", "20", "--title", "New Issue"])
      end

      expect(output).to include("Created issue")
      expect(output).to include("New Issue")
      expect(output).to include("PROJ-5")
    end

    it "creates an issue with all options" do
      expect(client).to receive(:post).with(
        "/api/v1/issues",
        body: {
          issue: {
            project_id: "20",
            title: "Full Issue",
            description: "A complete issue",
            issue_type: "bug",
            priority: "high",
            status: "in_progress",
            assigned_to: "5",
            due_date: "2026-01-15",
            labels: %w[urgent security]
          }
        }
      ).and_return({
        "id" => 6,
        "key" => "PROJ-6",
        "title" => "Full Issue",
        "status" => "in_progress",
        "issue_type" => "bug",
        "priority" => "high"
      })

      output = capture_stdout do
        described_class.start([
          "create", "20",
          "--title", "Full Issue",
          "--description", "A complete issue",
          "--type", "bug",
          "--priority", "high",
          "--status", "in_progress",
          "--assignee", "5",
          "--due-date", "2026-01-15",
          "--labels", "urgent", "security"
        ])
      end

      expect(output).to include("Created issue")
      expect(output).to include("Full Issue")
    end
  end

  describe "issues update" do
    let(:updated_issue) do
      {
        "id" => 1,
        "key" => "PROJ-1",
        "title" => "Updated Title",
        "status" => "in_progress",
        "priority" => "high"
      }
    end

    it "updates issue title" do
      expect(client).to receive(:patch).with(
        "/api/v1/issues/PROJ-1",
        body: {
          issue: { title: "Updated Title" }
        }
      ).and_return(updated_issue)

      output = capture_stdout do
        described_class.start(["update", "PROJ-1", "--title", "Updated Title"])
      end

      expect(output).to include("Updated issue")
      expect(output).to include("Updated Title")
    end

    it "updates issue priority" do
      expect(client).to receive(:patch).with(
        "/api/v1/issues/PROJ-1",
        body: {
          issue: { priority: "highest" }
        }
      ).and_return({
        "id" => 1,
        "key" => "PROJ-1",
        "title" => "Fix login bug",
        "status" => "in_progress",
        "priority" => "highest"
      })

      output = capture_stdout do
        described_class.start(%w[update PROJ-1 --priority highest])
      end

      expect(output).to include("Updated issue")
      expect(output).to include("highest")
    end

    it "errors when no updates provided" do
      output = capture_stdout do
        expect { described_class.start(%w[update PROJ-1]) }.to raise_error(SystemExit)
      end

      expect(output).to include("No updates provided")
    end
  end

  describe "issues transition" do
    it "transitions issue to new state" do
      expect(client).to receive(:post).with(
        "/api/v1/issues/PROJ-1/transition",
        body: {
          transition: { state: "done" }
        }
      ).and_return({
        "id" => 1,
        "key" => "PROJ-1",
        "title" => "Fix login bug",
        "status" => "done"
      })

      output = capture_stdout do
        described_class.start(%w[transition PROJ-1 done])
      end

      expect(output).to include("Transitioned")
      expect(output).to include("PROJ-1")
      expect(output).to include("done")
    end
  end

  describe "issues delete" do
    it "deletes issue with force flag" do
      expect(client).to receive(:delete).with(
        "/api/v1/issues/PROJ-1"
      )

      output = capture_stdout do
        described_class.start(%w[delete PROJ-1 --force])
      end

      expect(output).to include("Issue PROJ-1 has been deleted")
    end

    it "prompts for confirmation without force flag" do
      expect(client).to receive(:get).with(
        "/api/v1/issues/PROJ-1"
      ).and_return({ "id" => 1, "key" => "PROJ-1", "title" => "Fix login bug" })

      expect(prompt_double).to receive(:yes?).with(/Delete issue/).and_return(true)
      expect(client).to receive(:delete).with("/api/v1/issues/PROJ-1")

      output = capture_stdout do
        described_class.start(%w[delete PROJ-1])
      end

      expect(output).to include("deleted")
    end

    it "cancels deletion when user declines" do
      expect(client).to receive(:get).with(
        "/api/v1/issues/PROJ-1"
      ).and_return({ "id" => 1, "key" => "PROJ-1", "title" => "Fix login bug" })

      expect(prompt_double).to receive(:yes?).and_return(false)

      output = capture_stdout do
        described_class.start(%w[delete PROJ-1])
      end

      expect(output).to include("Cancelled")
    end
  end

  describe "issues schema" do
    let(:schema_response) do
      {
        "issue_types" => [
          { "name" => "Task", "description" => "A work item" },
          { "name" => "Bug", "description" => "A defect" }
        ],
        "statuses" => [
          { "name" => "backlog", "category" => "todo" },
          { "name" => "in_progress", "category" => "doing" },
          { "name" => "done", "category" => "done" }
        ],
        "priorities" => %w[low medium high critical],
        "custom_fields" => [
          { "key" => "sprint", "field_type" => "select", "name" => "Sprint" }
        ]
      }
    end

    it "shows issue schema" do
      expect(client).to receive(:get).with(
        "/api/v1/issues/schema",
        params: { project_id: "20" }
      ).and_return(schema_response)

      output = capture_stdout do
        described_class.start(%w[schema 20])
      end

      expect(output).to include("Issue Types")
      expect(output).to include("Task")
      expect(output).to include("Bug")
      expect(output).to include("Statuses")
      expect(output).to include("backlog")
      expect(output).to include("Priorities")
      expect(output).to include("Custom Fields")
      expect(output).to include("sprint")
    end
  end

  describe "issues create with custom_fields" do
    it "creates issue with custom fields" do
      expect(client).to receive(:post).with(
        "/api/v1/issues",
        body: {
          issue: hash_including(
            project_id: "20",
            title: "Issue with fields",
            custom_fields: { "sprint" => "Sprint 1" }
          )
        }
      ).and_return({
        "id" => 7,
        "key" => "PROJ-7",
        "title" => "Issue with fields",
        "status" => "backlog",
        "issue_type" => "task",
        "priority" => "medium"
      })

      output = capture_stdout do
        described_class.start([
          "create", "20",
          "--title", "Issue with fields",
          "--custom-fields", '{"sprint":"Sprint 1"}'
        ])
      end

      expect(output).to include("Created issue")
    end
  end

  describe "JSON output format" do
    let(:json_config) { test_config(output_format: "json") }

    before do
      Kiket.instance_variable_set(:@config, json_config)
    end

    it "outputs issues as JSON" do
      issues = [{ "id" => 1, "title" => "Test" }]
      expect(client).to receive(:get).and_return({ "data" => issues, "meta" => {} })

      output = capture_stdout do
        described_class.start(%w[list 20])
      end

      parsed = MultiJson.load(output)
      expect(parsed).to be_an(Array)
      expect(parsed.first["title"]).to eq("Test")
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
