# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "kiket/commands/audit"

RSpec.describe Kiket::Commands::Audit do
  let(:config) { test_config(output_format: "human") }
  let(:client) { instance_double(Kiket::Client) }
  let(:spinner_double) { instance_double(TTY::Spinner, auto_spin: true, success: true) }

  before(:each) do
    Kiket.reset!
    Kiket.instance_variable_set(:@config, config)
    allow(Kiket).to receive(:client).and_return(client)
    allow(TTY::Spinner).to receive(:new).and_return(spinner_double)
  end

  after(:each) do
    Kiket.reset!
  end

  describe "#anchors" do
    let(:anchors_response) do
      {
        "anchors" => [
          {
            "id" => 1,
            "merkle_root" => "0xabc123...",
            "tx_hash" => "0xdef456789012345678901234567890",
            "status" => "confirmed",
            "network" => "polygon_amoy",
            "leaf_count" => 42,
            "created_at" => "2026-01-15T10:00:00Z"
          },
          {
            "id" => 2,
            "merkle_root" => "0xghi789...",
            "tx_hash" => nil,
            "status" => "pending",
            "network" => "polygon_amoy",
            "leaf_count" => 15,
            "created_at" => "2026-01-15T11:00:00Z"
          }
        ]
      }
    end

    it "lists blockchain anchors with filters and JSON output" do
      # Test basic list
      expect(client).to receive(:get).with(
        "/api/v1/audit/anchors",
        params: { per_page: 25 }
      ).and_return(anchors_response)

      output = capture_stdout { described_class.start(%w[anchors]) }
      expect(output).to include("confirmed")
      expect(output).to include("42")
    end

    it "filters by status and network" do
      expect(client).to receive(:get).with(
        "/api/v1/audit/anchors",
        params: { per_page: 25, status: "confirmed", network: "polygon_mainnet" }
      ).and_return({ "anchors" => [] })

      output = capture_stdout { described_class.start(%w[anchors --status confirmed --network polygon_mainnet]) }
      expect(output).to include("No anchors found")
    end
  end

  describe "#proof" do
    let(:proof_response) do
      {
        "content_hash" => "0x1234567890abcdef",
        "proof" => ["0xaaa...", "0xbbb..."],
        "leaf_index" => 5,
        "merkle_root" => "0xrootabc123",
        "tx_hash" => "0xtxhash456",
        "block_number" => 12345,
        "network" => "polygon_amoy"
      }
    end

    it "fetches and displays proof for an audit record" do
      expect(client).to receive(:get).with(
        "/api/v1/audit/records/123/proof",
        params: {}
      ).and_return(proof_response)

      output = capture_stdout { described_class.start(%w[proof 123]) }
      parsed = MultiJson.load(output)
      expect(parsed["content_hash"]).to eq("0x1234567890abcdef")
    end

    it "saves proof to file with different record types" do
      expect(client).to receive(:get).with(
        "/api/v1/audit/records/456/proof",
        params: { record_type: "AIAuditLog" }
      ).and_return(proof_response)

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "test_proof.json")
        output = capture_stdout do
          described_class.start(["proof", "456", "--format", "file", "--output", output_path, "--type", "AIAuditLog"])
        end

        expect(output).to include("Proof saved to")
        expect(File.exist?(output_path)).to be true
      end
    end
  end

  describe "#verify" do
    let(:proof_data) do
      {
        "content_hash" => "0x1234567890abcdef",
        "proof" => ["0xaaa111", "0xbbb222"],
        "leaf_index" => 5,
        "merkle_root" => "0xrootabc123"
      }
    end

    let(:verify_response) do
      {
        "verified" => true,
        "proof_valid" => true,
        "blockchain_verified" => true,
        "network" => "polygon_amoy",
        "block_number" => 12345,
        "block_timestamp" => "2026-01-15T10:00:00Z",
        "explorer_url" => "https://amoy.polygonscan.com/tx/0x123"
      }
    end

    it "verifies proof via API from file or JSON string" do
      expect(client).to receive(:post).with(
        "/api/v1/audit/verify",
        body: proof_data
      ).and_return(verify_response)

      output = capture_stdout do
        described_class.start(["verify", "--json", MultiJson.dump(proof_data)])
      end

      expect(output).to include("VALID")
      expect(output).to include("polygon_amoy")
    end

    it "handles invalid proof response" do
      expect(client).to receive(:post).and_return({
        "verified" => false,
        "error" => "Proof path does not match merkle root"
      })

      Dir.mktmpdir do |dir|
        proof_file = File.join(dir, "proof.json")
        File.write(proof_file, MultiJson.dump(proof_data))

        output = capture_stdout do
          expect { described_class.start(["verify", proof_file]) }.to raise_error(SystemExit)
        end

        expect(output).to include("INVALID")
      end
    end

    it "verifies locally without API call" do
      local_proof = {
        "content_hash" => "0x" + ("a" * 64),
        "proof" => [],
        "leaf_index" => 0,
        "merkle_root" => "0x" + ("a" * 64)
      }

      Dir.mktmpdir do |dir|
        proof_file = File.join(dir, "proof.json")
        File.write(proof_file, MultiJson.dump(local_proof))

        output = capture_stdout { described_class.start(["verify", proof_file, "--local"]) }

        expect(output).to include("VALID")
        expect(output).to include("Merkle proof")
      end
    end

    it "requires proof file or --json option" do
      output = capture_stdout do
        expect { described_class.start(%w[verify]) }.to raise_error(SystemExit)
      end

      expect(output).to include("Please provide a proof file or --json option")
    end
  end

  describe "#export" do
    let(:pdf_content) { "%PDF-1.4 fake pdf content" }

    it "exports audit-trail report to file" do
      expect(client).to receive(:get_raw).with(
        "/api/v1/audit/reports/audit_trail.pdf",
        params: { from: "2026-01-01", to: "2026-01-31" }
      ).and_return(pdf_content)

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "audit_report.pdf")
        output = capture_stdout do
          described_class.start([
            "export", "audit-trail",
            "--start", "2026-01-01",
            "--end-date", "2026-01-31",
            "--output", output_path
          ])
        end

        expect(output).to include("Report saved to")
        expect(File.exist?(output_path)).to be true
        expect(File.read(output_path)).to eq(pdf_content)
      end
    end

    it "exports eu-ai-act report" do
      expect(client).to receive(:get_raw).with(
        "/api/v1/audit/reports/eu_ai_act.pdf",
        params: { from: "2026-01-01", to: "2026-06-30" }
      ).and_return(pdf_content)

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "eu_ai_act.pdf")
        output = capture_stdout do
          described_class.start([
            "export", "eu-ai-act",
            "--start", "2026-01-01",
            "--end-date", "2026-06-30",
            "--output", output_path
          ])
        end

        expect(output).to include("Report saved to")
      end
    end

    it "rejects invalid report type" do
      output = capture_stdout do
        expect {
          described_class.start([
            "export", "invalid-type",
            "--start", "2026-01-01",
            "--end-date", "2026-01-31"
          ])
        }.to raise_error(SystemExit)
      end

      expect(output).to include("Invalid report type")
      expect(output).to include("audit-trail")
    end
  end

  describe "#status" do
    it "shows blockchain audit status summary" do
      status_response = {
        "anchors" => [
          { "id" => 1, "status" => "confirmed", "merkle_root" => "0xabc...", "leaf_count" => 42, "network" => "polygon_amoy", "explorer_url" => "https://amoy.polygonscan.com/tx/0x123" },
          { "id" => 2, "status" => "confirmed", "merkle_root" => "0xdef...", "leaf_count" => 38, "network" => "polygon_amoy" },
          { "id" => 3, "status" => "pending", "merkle_root" => "0xghi...", "leaf_count" => 25, "network" => "polygon_amoy" }
        ]
      }

      expect(client).to receive(:get).with(
        "/api/v1/audit/anchors",
        params: { per_page: 5 }
      ).and_return(status_response)

      output = capture_stdout { described_class.start(%w[status]) }

      expect(output).to include("Blockchain Audit Status")
      expect(output).to include("Confirmed: 2")
      expect(output).to include("Pending:   1")
      expect(output).to include("Latest Anchor")
    end

    it "handles empty anchors" do
      expect(client).to receive(:get).and_return({ "anchors" => [] })

      output = capture_stdout { described_class.start(%w[status]) }

      expect(output).to include("No blockchain anchors yet")
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
