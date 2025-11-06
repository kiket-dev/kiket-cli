# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Analytics < Base
      desc "report usage", "Generate usage report"
      option :product, type: :string, desc: "Product installation ID"
      option :start_date, type: :string, desc: "Start date (YYYY-MM-DD)"
      option :end_date, type: :string, desc: "End date (YYYY-MM-DD)"
      def usage
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        params = {
          organization: org,
          start_date: options[:start_date],
          end_date: options[:end_date]
        }
        params[:product_installation] = options[:product] if options[:product]

        spinner = spinner("Generating usage report...")
        spinner.auto_spin

        response = client.get("/api/v1/analytics/usage", params: params.compact)

        spinner.success("Report generated")

        if output_format == "human"
          puts "\n#{pastel.bold('Usage Report')}"
          puts "Organization: #{org}"
          puts "Period: #{response['period']['start']} to #{response['period']['end']}"
          puts ""

          puts pastel.bold("Summary:")
          response["summary"].each do |metric, value|
            puts "  #{metric}: #{format_metric(value)}"
          end
          puts ""

          if response["by_product"]
            puts pastel.bold("By Product:")
            response["by_product"].each do |product, metrics|
              puts "  #{product}:"
              metrics.each do |metric, value|
                puts "    #{metric}: #{format_metric(value)}"
              end
            end
          end
        else
          output_data(response["details"], headers: response["details"].first&.keys)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "report billing", "Generate billing report"
      option :month, type: :string, desc: "Month (YYYY-MM)"
      def billing
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        params = {
          organization: org,
          month: options[:month] || Time.now.strftime("%Y-%m")
        }

        spinner = spinner("Generating billing report...")
        spinner.auto_spin

        response = client.get("/api/v1/analytics/billing", params: params)

        spinner.success("Report generated")

        if output_format == "human"
          puts "\n#{pastel.bold('Billing Report')}"
          puts "Organization: #{org}"
          puts "Month: #{params[:month]}"
          puts ""

          puts pastel.bold("Subscription:")
          puts "  Plan: #{response['subscription']['plan']}"
          puts "  Amount: #{format_currency(response['subscription']['amount'])}"
          puts ""

          if response["usage_charges"]&.any?
            puts pastel.bold("Usage Charges:")
            response["usage_charges"].each do |charge|
              puts "  #{charge['metric']}: #{format_currency(charge['amount'])} (#{charge['quantity']} units)"
            end
            puts ""
          end

          puts pastel.bold("Total: #{format_currency(response['total'])}")
        else
          output_json(response)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "dashboard open", "Open analytics dashboard in browser"
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
        dashboard_url = "#{config.api_base_url}/analytics/dashboard?token=#{response['token']}"

        info "Opening dashboard in browser..."

        # Try to open in default browser
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

      def format_currency(amount)
        "$#{(amount / 100.0).round(2)}"
      end
    end
  end
end
