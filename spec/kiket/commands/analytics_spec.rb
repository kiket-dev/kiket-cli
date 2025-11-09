# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "kiket/commands/analytics"

RSpec.describe Kiket::Commands::Analytics do
  let(:config) { test_config(output_format: "human") }
  let(:client) { instance_double(Kiket::Client) }
  let(:spinner_double) { instance_double(TTY::Spinner, auto_spin: true, success: true) }

  before do
    Kiket.reset!
    Kiket.instance_variable_set(:@config, config)
    allow(Kiket).to receive(:client).and_return(client)
    allow(TTY::Spinner).to receive(:new).and_return(spinner_double)
  end

  after do
    Kiket.reset!
  end

  describe "analytics usage" do
    it "requests usage report with expected parameters and prints summary" do
      response = {
        "start_at" => "2025-11-01T00:00:00Z",
        "end_at" => "2025-11-02T00:00:00Z",
        "unit" => "count",
        "totals" => {
          "ai.request" => { "quantity" => 42, "unit" => "count", "estimated_cost_cents" => 300 },
          "workflow.transition" => { "quantity" => 12, "unit" => "count", "estimated_cost_cents" => 0 }
        },
        "series" => {
          "ai.request" => {
            "2025-11-01" => 20,
            "2025-11-02" => 22
          }
        }
      }

      expect(client).to receive(:get).with(
        "/api/v1/analytics/usage",
        params: hash_including(
          organization: "test-org",
          start_at: "2025-11-01",
          end_at: "2025-11-02",
          group_by: "day"
        )
      ).and_return(response)

      output = capture_stdout do
        described_class.start(%w[usage --start-date 2025-11-01 --end-date 2025-11-02 --group-by day])
      end

      expect(output).to include("Usage Report")
      expect(output).to include("ai.request")
      expect(output).to include("$3.00")
      expect(output).to include("Daily Breakdown")
    end
  end

  describe "analytics billing" do
    it "requests billing report and prints invoice summary" do
      billing_response = {
        "start_at" => "2025-11-01T00:00:00Z",
        "end_at" => "2025-11-30T23:59:59Z",
        "totals" => {
          "invoiced_cents" => 12_300,
          "paid_cents" => 12_300,
          "outstanding_cents" => 0
        },
        "invoices" => [
          {
            "id" => 1,
            "stripe_invoice_id" => "in_test",
            "status" => "paid",
            "amount_cents" => 12_300,
            "issued_at" => "2025-11-05T10:00:00Z",
            "paid_at" => "2025-11-06T08:00:00Z"
          }
        ]
      }

      expect(client).to receive(:get).with(
        "/api/v1/analytics/billing",
        params: hash_including(
          organization: "test-org",
          start_at: "2025-11-01",
          end_at: "2025-11-30"
        )
      ).and_return(billing_response)

      output = capture_stdout do
        described_class.start(%w[billing --start-date 2025-11-01 --end-date 2025-11-30])
      end

      expect(output).to include("Billing Report")
      expect(output).to include("Invoiced: $123.00")
      expect(output).to include("in_test")
      expect(output).to include("paid")
    end
  end

  describe "analytics queries" do
    it "lists query definitions for a project" do
      response = {
        "project" => { "id" => 7, "name" => "Delivery Ops" },
        "queries" => [
          {
            "id" => "cycle_time_trend",
            "name" => "Cycle Time Trend",
            "model" => "fct_cycle_time",
            "tags" => %w[delivery dashboards],
            "parameters" => [
              { "name" => "project_id" }
            ],
            "source" => "definitions/demo/.kiket/queries/cycle.yaml"
          }
        ]
      }

      expect(client).to receive(:get).with(
        "/api/v1/projects/7/queries",
        params: { organization: "test-org" }
      ).and_return(response)

      output = capture_stdout do
        described_class.start(%w[queries 7])
      end

      expect(output).to include("cycle_time_trend")
      expect(output).to include("fct_cycle_time")
      expect(output).to include("project_id")
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
