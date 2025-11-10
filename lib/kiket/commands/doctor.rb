# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Doctor < Base
      desc "run", "Run diagnostic health checks"
      map "run" => :execute
      option :extensions, type: :boolean, desc: "Check extension health"
      option :workflows, type: :boolean, desc: "Check workflow health"
      option :product, type: :string, desc: "Product installation ID"
      def execute
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        puts pastel.bold("Kiket Health Check\n")

        checks = []

        # API connectivity
        checks << check_api_connectivity

        # Authentication
        checks << check_authentication

        # Organization access
        checks << check_organization_access(org)

        # Product installation health
        checks << check_product_installation(options[:product]) if options[:product]

        # Extension health
        checks.concat(check_extensions(org, options[:product])) if options[:extensions] || options[:product]

        # Workflow health
        checks.concat(check_workflows(org)) if options[:workflows]

        # Secret health
        checks.concat(check_secrets(org, options[:product]))

        # Display results
        display_check_results(checks)

        # Summary
        errors = checks.count { |c| c[:status] == :error }
        warnings = checks.count { |c| c[:status] == :warning }

        puts ""
        if errors.zero? && warnings.zero?
          success "All checks passed!"
        elsif errors.zero?
          warning "#{warnings} warning(s) found"
        else
          error "#{errors} error(s) and #{warnings} warning(s) found"
          exit 1
        end
      rescue StandardError => e
        handle_error(e)
      end

      private

      def check_api_connectivity
        client.get("/api/v1/health")
        { category: "API", name: "Connectivity", status: :ok, message: "API reachable" }
      rescue StandardError => e
        { category: "API", name: "Connectivity", status: :error, message: "Cannot reach API: #{e.message}" }
      end

      def check_authentication
        response = client.get("/api/v1/me")
        { category: "Auth", name: "Token", status: :ok, message: "Valid (#{response["email"]})" }
      rescue UnauthorizedError
        { category: "Auth", name: "Token", status: :error, message: "Invalid or expired" }
      rescue StandardError => e
        { category: "Auth", name: "Token", status: :error, message: e.message }
      end

      def check_organization_access(org)
        response = client.get("/api/v1/organizations/#{org}")
        { category: "Org", name: "Access", status: :ok, message: response["name"] }
      rescue NotFoundError
        { category: "Org", name: "Access", status: :error, message: "Organization not found" }
      rescue ForbiddenError
        { category: "Org", name: "Access", status: :error, message: "Access denied" }
      rescue StandardError => e
        { category: "Org", name: "Access", status: :error, message: e.message }
      end

      def check_product_installation(installation_id)
        response = client.get("/api/v1/marketplace/installations/#{installation_id}")
        installation = response["installation"]

        status = case installation["status"]
                 when "active" then :ok
                 when "installing", "upgrading" then :warning
                 else :error
                 end

        {
          category: "Product",
          name: installation["product_name"],
          status: status,
          message: installation["status"]
        }
      rescue StandardError => e
        { category: "Product", name: "Installation", status: :error, message: e.message }
      end

      def check_extensions(org, product_id = nil)
        checks = []

        begin
          params = { organization: org }
          params[:product_installation] = product_id if product_id

          response = client.get("/api/v1/extensions", params: params)

          if response["extensions"].empty?
            checks << {
              category: "Extensions",
              name: "Count",
              status: :warning,
              message: "No extensions configured"
            }
          else
            checks << {
              category: "Extensions",
              name: "Count",
              status: :ok,
              message: "#{response["extensions"].size} extensions"
            }

            # Check health of each extension
            response["extensions"].each do |ext|
              health_status = ext.dig("health", "status")
              status = case health_status
                       when "healthy" then :ok
                       when "degraded" then :warning
                       else :error
                       end

              checks << {
                category: "Extensions",
                name: ext["name"],
                status: status,
                message: ext.dig("health", "message") || health_status
              }
            end
          end
        rescue StandardError => e
          checks << {
            category: "Extensions",
            name: "Health Check",
            status: :error,
            message: e.message
          }
        end

        checks
      end

      def check_workflows(org)
        checks = []

        begin
          response = client.get("/api/v1/workflows", params: { organization: org })

          if response["workflows"].empty?
            checks << {
              category: "Workflows",
              name: "Count",
              status: :warning,
              message: "No workflows configured"
            }
          else
            checks << {
              category: "Workflows",
              name: "Count",
              status: :ok,
              message: "#{response["workflows"].size} workflows"
            }

            # Check for validation errors
            response["workflows"].each do |workflow|
              next unless workflow["validation_errors"]&.any?

              checks << {
                category: "Workflows",
                name: workflow["name"],
                status: :error,
                message: "Validation errors"
              }
            end
          end
        rescue StandardError => e
          checks << {
            category: "Workflows",
            name: "Health Check",
            status: :error,
            message: e.message
          }
        end

        checks
      end

      def check_secrets(org, product_id = nil)
        checks = []

        begin
          params = { organization: org }
          params[:product_installation] = product_id if product_id

          response = client.get("/api/v1/secrets/health", params: params)

          checks << {
            category: "Secrets",
            name: "Count",
            status: :ok,
            message: "#{response["secret_count"]} secrets"
          }

          # Check for expiring secrets
          if response["expiring_soon"]&.any?
            checks << {
              category: "Secrets",
              name: "Expiration",
              status: :warning,
              message: "#{response["expiring_soon"].size} secrets expiring soon"
            }
          end

          # Check for invalid secrets
          if response["invalid"]&.any?
            checks << {
              category: "Secrets",
              name: "Validity",
              status: :error,
              message: "#{response["invalid"].size} invalid secrets"
            }
          end
        rescue StandardError => e
          checks << {
            category: "Secrets",
            name: "Health Check",
            status: :warning,
            message: "Unable to check secrets: #{e.message}"
          }
        end

        checks
      end

      def display_check_results(checks)
        # Group by category
        grouped = checks.group_by { |c| c[:category] }

        grouped.each do |category, category_checks|
          puts pastel.bold("\n#{category}:")

          category_checks.each do |check|
            icon = case check[:status]
                   when :ok then pastel.green("✓")
                   when :warning then pastel.yellow("⚠")
                   when :error then pastel.red("✗")
                   end

            puts "  #{icon} #{check[:name]}: #{check[:message]}"
          end
        end
      end
    end
  end
end
