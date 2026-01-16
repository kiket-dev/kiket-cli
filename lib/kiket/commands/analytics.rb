# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Analytics < Base
      desc "usage", "Generate usage report"
      option :product, type: :string, desc: "Product installation ID"
      option :start_date, type: :string, desc: "Start date (YYYY-MM-DD)"
      option :end_date, type: :string, desc: "End date (YYYY-MM-DD)"
      option :group_by, type: :string, enum: %w[day], desc: "Grouping option (currently supports: day)"
      def usage
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        params = {
          organization: org,
          start_at: options[:start_date],
          end_at: options[:end_date],
          group_by: options[:group_by]
        }
        params[:product_installation] = options[:product] if options[:product]

        spinner = spinner("Generating usage report...")
        spinner.auto_spin

        response = client.get("/api/v1/analytics/usage", params: params.compact)

        spinner.success("Report generated")

        totals = response.fetch("totals", {})
        series = response.fetch("series", {})

        if output_format == "human"
          puts "\n#{pastel.bold("Usage Report")}"
          puts "Organization: #{org}"
          puts "Period: #{response["start_at"]} → #{response["end_at"]}"
          puts ""

          if totals.empty?
            puts pastel.yellow("No usage recorded in the selected window.")
            return
          end

          headers = %w[metric quantity unit estimated_cost]
          rows = totals.map do |metric, data|
            [
              metric,
              data["quantity"],
              data["unit"] || response["unit"] || "count",
              format_currency(data["estimated_cost_cents"])
            ]
          end

          table = TTY::Table.new(headers, rows)
          puts pastel.bold("Totals")
          puts table.render(:unicode, padding: [0, 1])

          unless series.empty?
            puts "\n#{pastel.bold("Daily Breakdown")}"
            series.each do |metric, timeline|
              puts pastel.cyan("  #{metric}")
              timeline.sort.each do |date, quantity|
                puts "    #{date}: #{quantity}"
              end
            end
          end
        else
          dataset = totals.map do |metric, data|
            {
              metric: metric,
              quantity: data["quantity"],
              unit: data["unit"] || response["unit"],
              estimated_cost_cents: data["estimated_cost_cents"]
            }
          end
          output_data(dataset, headers: %i[metric quantity unit estimated_cost_cents])
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "billing", "Generate billing report"
      option :start_date, type: :string, desc: "Start date (YYYY-MM-DD)"
      option :end_date, type: :string, desc: "End date (YYYY-MM-DD)"
      def billing
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        params = {
          organization: org,
          start_at: options[:start_date],
          end_at: options[:end_date]
        }

        spinner = spinner("Generating billing report...")
        spinner.auto_spin

        response = client.get("/api/v1/analytics/billing", params: params)

        spinner.success("Report generated")

        if output_format == "human"
          puts "\n#{pastel.bold("Billing Report")}"
          puts "Organization: #{org}"
          puts "Period: #{response["start_at"]} → #{response["end_at"]}"
          puts ""

          totals = response.fetch("totals", {})
          puts pastel.bold("Totals:")
          puts "  Invoiced: #{format_currency(totals["invoiced_cents"])}"
          puts "  Paid: #{format_currency(totals["paid_cents"])}"
          puts "  Outstanding: #{format_currency(totals["outstanding_cents"])}"
          puts ""

          invoices = response.fetch("invoices", [])
          if invoices.empty?
            puts pastel.yellow("No invoices issued in this period.")
          else
            puts pastel.bold("Invoices:")
            invoices.each do |invoice|
              puts "  #{invoice["stripe_invoice_id"] || invoice["id"]}"
              puts "    Status: #{invoice["status"]}"
              puts "    Amount: #{format_currency(invoice["amount_cents"])}"
              puts "    Issued: #{invoice["issued_at"]}"
              puts "    Paid: #{invoice["paid_at"] || "—"}"
            end
          end
        else
          output_json(response)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "open", "Open analytics dashboard in browser"
      option :product, type: :string, desc: "Product installation ID"
      def open
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        params = { organization: org }
        params[:product_installation] = options[:product] if options[:product]

        response = client.post("/api/v1/analytics/dashboard/token", body: params)
        token = response["token"]
        base_url = config.api_base_url
        dashboard_url = "#{base_url}/analytics/dashboard?token=#{token}"

        info "Opening dashboard in browser..."

        # Try to open in default browser
        # Note: URL is passed as separate argument to prevent command injection
        require "open3"
        case RbConfig::CONFIG["host_os"]
        when /darwin/
          Open3.capture3("open", dashboard_url)
        when /linux/
          Open3.capture3("xdg-open", dashboard_url)
        when /mswin|mingw|cygwin/
          Open3.capture3("start", dashboard_url)
        else
          info "Unable to open browser automatically"
          puts "\nDashboard URL: #{dashboard_url}"
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "queries PROJECT_ID", "List query definitions for a project"
      option :tag, type: :string, desc: "Filter by tag"
      def queries(project_id)
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        response = client.get("/api/v1/projects/#{project_id}/queries", params: { organization: org })
        entries = response.fetch("queries", [])

        entries = entries.select { |entry| Array(entry["tags"]).include?(options[:tag]) } if options[:tag]

        if output_format == "human"
          if entries.empty?
            warning "No queries found for project #{response.dig("project", "name") || project_id}."
            return
          end

          rows = entries.map do |entry|
            {
              id: entry["id"],
              name: entry["name"],
              model: entry["model"],
              tags: Array(entry["tags"]).join(", "),
              parameters: format_query_parameters(entry["parameters"]),
              source: entry["source"]
            }
          end

          output_data(rows, headers: %i[id name model tags parameters source])
        else
          output_data(entries, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      private

      def format_metric(value)
        if value.is_a?(Numeric)
          if value >= 1_000_000
            "#{(value / 1_000_000.0).round(2)}M"
          elsif value >= 1_000
            "#{(value / 1_000.0).round(2)}K"
          else
            value.to_s
          end
        else
          value.to_s
        end
      end

      def format_currency(cents)
        cents = cents.to_i
        format("$%.2f", cents / 100.0)
      end

      def format_query_parameters(parameters)
        Array(parameters).map { |param| param["name"] }.compact.join(", ")
      end
    end
  end
end
