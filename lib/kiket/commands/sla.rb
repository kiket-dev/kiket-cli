# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Sla < Base
      desc "events", "List SLA alerts for an organization"
      option :project, type: :string, desc: "Project ID"
      option :issue, type: :string, desc: "Issue ID"
      option :state, type: :string, enum: %w[imminent breached recovered], desc: "Filter by state"
      option :limit, type: :numeric, desc: "Max events to return (default: 50)"
      def events
        ensure_authenticated!
        org = organization
        unless org
          error "Organization required (use --org or set a default with 'kiket configure org')"
          exit 1
        end

        params = {
          organization: org,
          project_id: options[:project],
          issue_id: options[:issue],
          state: options[:state],
          limit: options[:limit]
        }.compact

        spinner = spinner("Fetching SLA events...")
        spinner.auto_spin

        response = client.get("/api/v1/sla_events", params: params)

        spinner.success("Fetched events")

        rows = response.fetch("data", []).map do |event|
          definition = event["definition"] || {}
          metrics = event["metrics"] || {}
          {
            id: event["id"],
            issue_id: event["issue_id"],
            project_id: event["project_id"],
            state: event["state"],
            status: definition["status"],
            duration_minutes: metrics["duration_minutes"],
            overdue_minutes: metrics["overdue_minutes"],
            triggered_at: event["triggered_at"],
            resolved_at: event["resolved_at"]
          }
        end

        if rows.empty?
          puts pastel.yellow("No SLA events found.")
          return
        end

        headers = %i[id issue_id project_id state status duration_minutes overdue_minutes triggered_at resolved_at]
        output_data(rows, headers:)
      rescue StandardError => e
        handle_error(e)
      end
    end
  end
end
