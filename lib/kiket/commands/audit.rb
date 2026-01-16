# frozen_string_literal: true

require_relative "base"
require "json"
require "digest"

module Kiket
  module Commands
    class Audit < Base
      desc "anchors", "List blockchain anchors"
      option :status, type: :string, desc: "Filter by status (pending, submitted, confirmed, failed)"
      option :network, type: :string, desc: "Filter by network (polygon_amoy, polygon_mainnet)"
      option :limit, type: :numeric, default: 25, desc: "Number of results"
      option :format, type: :string, default: "table", desc: "Output format (table, json)"
      def anchors
        ensure_authenticated!

        params = { per_page: options[:limit] }
        params[:status] = options[:status] if options[:status]
        params[:network] = options[:network] if options[:network]

        spinner = spinner("Fetching anchors...")
        spinner.auto_spin

        response = client.get("/api/v1/audit/anchors", params: params)
        spinner.success

        anchors_data = response["anchors"] || []

        if anchors_data.empty?
          info "No anchors found"
          return
        end

        if options[:format] == "json"
          say JSON.pretty_generate(anchors_data)
        else
          render_anchors_table(anchors_data)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "proof RECORD_ID", "Get blockchain proof for an audit record"
      option :format, type: :string, default: "json", desc: "Output format (json, file)"
      option :output, type: :string, desc: "Output file path (for --format=file)"
      option :type, type: :string, default: "AuditLog", desc: "Record type (AuditLog, AIAuditLog)"
      def proof(record_id)
        ensure_authenticated!

        spinner = spinner("Fetching proof...")
        spinner.auto_spin

        params = options[:type] == "AuditLog" ? {} : { record_type: options[:type] }
        response = client.get("/api/v1/audit/records/#{record_id}/proof", params: params)
        spinner.success

        proof_data = response

        if options[:format] == "file"
          output_path = options[:output] || "proof_#{record_id}.json"
          File.write(output_path, JSON.pretty_generate(proof_data))
          success "Proof saved to #{output_path}"
        else
          say JSON.pretty_generate(proof_data)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "verify [PROOF_FILE]", "Verify a blockchain proof"
      option :json, type: :string, desc: "Proof JSON string (alternative to file)"
      option :local, type: :boolean, default: false, desc: "Verify locally without API call"
      def verify(proof_file = nil)
        # Load proof data
        proof_data = if options[:json]
                       JSON.parse(options[:json])
                     elsif proof_file
                       JSON.parse(File.read(proof_file))
                     else
                       error "Please provide a proof file or --json option"
                       exit 1
                     end

        if options[:local]
          verify_locally(proof_data)
        else
          verify_via_api(proof_data)
        end
      rescue JSON::ParserError => e
        error "Invalid JSON: #{e.message}"
        exit 1
      rescue StandardError => e
        handle_error(e)
      end

      desc "export TYPE", "Export blockchain compliance report"
      option :start, type: :string, required: true, desc: "Start date (YYYY-MM-DD)"
      option :end_date, type: :string, required: true, desc: "End date (YYYY-MM-DD)"
      option :output, type: :string, desc: "Output file path (defaults to report_TYPE_DATE.pdf)"
      long_desc <<-LONGDESC
        Export compliance reports with blockchain verification proofs.

        Report types:
          audit-trail - Full audit trail with Merkle proofs
          eu-ai-act   - EU AI Act Article 12 compliance report

        Examples:
          $ kiket audit export audit-trail --start 2026-01-01 --end-date 2026-01-31
          $ kiket audit export eu-ai-act --start 2026-01-01 --end-date 2026-06-30 --output my_report.pdf
      LONGDESC
      def export(report_type)
        ensure_authenticated!

        valid_types = %w[audit-trail eu-ai-act]
        unless valid_types.include?(report_type)
          error "Invalid report type: #{report_type}"
          error "Valid types: #{valid_types.join(", ")}"
          exit 1
        end

        spinner = spinner("Generating #{report_type} report...")
        spinner.auto_spin

        endpoint = case report_type
                   when "audit-trail"
                     "/api/v1/audit/reports/audit_trail.pdf"
                   when "eu-ai-act"
                     "/api/v1/audit/reports/eu_ai_act.pdf"
                   end

        params = {
          from: options[:start],
          to: options[:end_date]
        }

        # Make raw request for binary PDF response
        response = client.get_raw(endpoint, params: params)
        spinner.success

        output_path = options[:output] || "#{report_type.gsub("-", "_")}_#{Date.today}.pdf"
        File.binwrite(output_path, response)

        success "Report saved to #{output_path}"
      rescue StandardError => e
        handle_error(e)
      end

      desc "status", "Show blockchain audit status for the organization"
      def status
        ensure_authenticated!

        spinner = spinner("Fetching audit status...")
        spinner.auto_spin

        # Get recent anchors to show status
        response = client.get("/api/v1/audit/anchors", params: { per_page: 5 })
        spinner.success

        anchors = response["anchors"] || []

        say ""
        say "Blockchain Audit Status", :bold
        say "=" * 40

        if anchors.empty?
          info "No blockchain anchors yet"
          info "Audit records are anchored to the blockchain hourly"
          return
        end

        # Count by status
        confirmed = anchors.count { |a| a["status"] == "confirmed" }
        pending = anchors.count { |a| a["status"] == "pending" }
        submitted = anchors.count { |a| a["status"] == "submitted" }
        failed = anchors.count { |a| a["status"] == "failed" }

        say ""
        say "Recent Anchors (last 5):"
        say "  Confirmed: #{confirmed}"
        say "  Pending:   #{pending}"
        say "  Submitted: #{submitted}"
        say "  Failed:    #{failed}"

        latest = anchors.first
        if latest
          say ""
          say "Latest Anchor:", :bold
          say "  Merkle Root: #{latest["merkle_root"]}"
          say "  Records:     #{latest["leaf_count"]}"
          say "  Status:      #{latest["status"]}"
          say "  Network:     #{latest["network"]}"
          say "  Explorer:    #{latest["explorer_url"]}" if latest["explorer_url"]
        end
      rescue StandardError => e
        handle_error(e)
      end

      private

      def render_anchors_table(anchors)
        headers = %w[ID Status Records Network Created TX]

        rows = anchors.map do |anchor|
          tx_short = anchor["tx_hash"] ? "#{anchor["tx_hash"][0..10]}..." : "-"
          created = begin
            Time.parse(anchor["created_at"]).strftime("%Y-%m-%d %H:%M")
          rescue StandardError
            anchor["created_at"]
          end

          [
            anchor["id"],
            colorize_status(anchor["status"]),
            anchor["leaf_count"],
            anchor["network"]&.gsub("polygon_", ""),
            created,
            tx_short
          ]
        end

        table = TTY::Table.new(headers, rows)
        say table.render(:unicode, padding: [0, 1])
      end

      def colorize_status(status)
        case status
        when "confirmed" then set_color(status, :green)
        when "pending" then set_color(status, :yellow)
        when "submitted" then set_color(status, :blue)
        when "failed" then set_color(status, :red)
        else status
        end
      end

      def verify_locally(proof_data)
        spinner = spinner("Verifying proof locally...")
        spinner.auto_spin

        valid = merkle_verify(
          content_hash: proof_data["content_hash"],
          proof_path: proof_data["proof"],
          leaf_index: proof_data["leaf_index"],
          merkle_root: proof_data["merkle_root"]
        )

        spinner.success

        if valid
          success "Proof is VALID"
          say ""
          say "Content Hash:  #{proof_data["content_hash"]}"
          say "Merkle Root:   #{proof_data["merkle_root"]}"
          say "Leaf Index:    #{proof_data["leaf_index"]}"
          say ""
          info "Note: This only verifies the Merkle proof cryptographically."
          info "Use --no-local to also verify the anchor exists on-chain."
        else
          error "Proof is INVALID"
          exit 1
        end
      end

      def verify_via_api(proof_data)
        ensure_authenticated!

        spinner = spinner("Verifying proof via API...")
        spinner.auto_spin

        response = client.post("/api/v1/audit/verify", body: proof_data)
        spinner.success

        if response["verified"]
          success "Proof is VALID"
          say ""
          say "Proof Valid:       #{response["proof_valid"]}"
          say "Blockchain Verified: #{response["blockchain_verified"]}"

          if response["blockchain_verified"]
            say ""
            say "Blockchain Details:", :bold
            say "  Network:     #{response["network"]}"
            say "  Block:       #{response["block_number"]}"
            say "  Timestamp:   #{response["block_timestamp"]}"
            say "  Explorer:    #{response["explorer_url"]}" if response["explorer_url"]
          end
        else
          error "Proof is INVALID"
          error "Reason: #{response["error"]}" if response["error"]
          exit 1
        end
      end

      def merkle_verify(content_hash:, proof_path:, leaf_index:, merkle_root:)
        normalize_hash = lambda { |h|
          hex = h.start_with?("0x") ? h[2..] : h
          [hex].pack("H*")
        }

        hash_pair = lambda { |left, right|
          left, right = right, left if left > right
          Digest::SHA256.digest(left + right)
        }

        current = normalize_hash.call(content_hash)
        idx = leaf_index

        proof_path.each do |sibling_hex|
          sibling = normalize_hash.call(sibling_hex)
          current = if idx.even?
                      hash_pair.call(current, sibling)
                    else
                      hash_pair.call(sibling, current)
                    end
          idx /= 2
        end

        expected = normalize_hash.call(merkle_root)
        current == expected
      end
    end
  end
end
