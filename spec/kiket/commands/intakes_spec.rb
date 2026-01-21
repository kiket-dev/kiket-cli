# frozen_string_literal: true

require "spec_helper"
require "kiket/commands/intakes"

RSpec.describe Kiket::Commands::Intakes do
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

  describe "#list" do
    it "fetches intake forms and prints output" do
      response = {
        "data" => [
          {
            "id" => "form-1",
            "key" => "bug-report",
            "name" => "Bug Report",
            "slug" => "bug-report",
            "active" => true,
            "public" => true,
            "embed_enabled" => false,
            "stats" => { "submissions_count" => 42 },
            "created_at" => "2024-01-15T10:00:00Z"
          }
        ]
      }

      expect(client).to receive(:get)
        .with("/api/v1/intake_forms", params: hash_including(organization: "acme", project_id: "proj-1"))
        .and_return(response)

      expect do
        described_class.start(["list", "--project", "proj-1"])
      end.not_to raise_error
    end

    it "filters by active and public" do
      response = { "data" => [] }

      expect(client).to receive(:get)
        .with("/api/v1/intake_forms", params: hash_including(active: true, public: true))
        .and_return(response)

      expect do
        described_class.start(["list", "--project", "proj-1", "--active", "--public"])
      end.not_to raise_error
    end
  end

  describe "#show" do
    it "fetches and displays form details" do
      response = {
        "data" => {
          "id" => "form-1",
          "key" => "bug-report",
          "name" => "Bug Report",
          "slug" => "bug-report",
          "active" => true,
          "public" => true,
          "embed_enabled" => true,
          "rate_limit" => 100,
          "requires_approval" => true,
          "form_url" => "https://forms.kiket.dev/bug-report",
          "created_at" => "2024-01-15T10:00:00Z",
          "fields" => [
            { "label" => "Title", "field_type" => "text", "required" => true },
            { "label" => "Description", "field_type" => "textarea", "required" => false }
          ]
        }
      }

      expect(client).to receive(:get)
        .with("/api/v1/intake_forms/bug-report", params: hash_including(organization: "acme"))
        .and_return(response)

      expect do
        described_class.start(["show", "bug-report", "--project", "proj-1"])
      end.not_to raise_error
    end
  end

  describe "#submissions" do
    it "fetches submissions for a form" do
      response = {
        "data" => [
          {
            "id" => "sub-1",
            "status" => "pending",
            "submitted_by" => { "name" => "John Doe" },
            "submitted_at" => "2024-01-15T10:00:00Z",
            "processed_at" => nil,
            "ip_address" => "192.168.1.1"
          }
        ]
      }

      expect(client).to receive(:get)
        .with("/api/v1/intake_forms/bug-report/submissions", params: hash_including(organization: "acme"))
        .and_return(response)

      expect do
        described_class.start(["submissions", "bug-report", "--project", "proj-1"])
      end.not_to raise_error
    end

    it "filters by status" do
      response = { "data" => [] }

      expect(client).to receive(:get)
        .with("/api/v1/intake_forms/bug-report/submissions", params: hash_including(status: "pending"))
        .and_return(response)

      expect do
        described_class.start(["submissions", "bug-report", "--project", "proj-1", "--status", "pending"])
      end.not_to raise_error
    end
  end

  describe "#approve" do
    it "approves a pending submission" do
      expect(client).to receive(:post)
        .with("/api/v1/intake_forms/bug-report/submissions/sub-1/approve",
              body: hash_including(organization: "acme"))

      expect do
        described_class.start(["approve", "bug-report", "sub-1", "--project", "proj-1"])
      end.not_to raise_error
    end

    it "includes notes when provided" do
      expect(client).to receive(:post)
        .with("/api/v1/intake_forms/bug-report/submissions/sub-1/approve",
              body: hash_including(notes: "Looks good"))

      expect do
        described_class.start(["approve", "bug-report", "sub-1", "--project", "proj-1", "--notes", "Looks good"])
      end.not_to raise_error
    end
  end

  describe "#reject" do
    it "rejects a pending submission" do
      expect(client).to receive(:post)
        .with("/api/v1/intake_forms/bug-report/submissions/sub-1/reject",
              body: hash_including(organization: "acme"))

      expect do
        described_class.start(["reject", "bug-report", "sub-1", "--project", "proj-1"])
      end.not_to raise_error
    end
  end

  describe "#stats" do
    it "fetches form statistics" do
      response = {
        "data" => {
          "total_submissions" => 100,
          "pending" => 10,
          "approved" => 80,
          "rejected" => 5,
          "converted" => 5,
          "avg_processing_time" => "2 hours"
        }
      }

      expect(client).to receive(:get)
        .with("/api/v1/intake_forms/bug-report/stats", params: hash_including(organization: "acme"))
        .and_return(response)

      expect do
        described_class.start(["stats", "bug-report", "--project", "proj-1"])
      end.not_to raise_error
    end
  end

  describe "#usage" do
    it "fetches organization usage info" do
      response = {
        "data" => {
          "forms" => { "current" => 3, "limit" => 5, "status" => "ok" },
          "submissions" => { "current" => 250, "limit" => 500, "status" => "approaching", "resets_at" => "2024-02-01" }
        }
      }

      expect(client).to receive(:get)
        .with("/api/v1/usage/intake_forms", params: hash_including(organization: "acme"))
        .and_return(response)

      expect do
        described_class.start(["usage"])
      end.not_to raise_error
    end
  end
end
