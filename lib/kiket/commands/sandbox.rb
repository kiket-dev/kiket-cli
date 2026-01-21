# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Sandbox < Base
      desc "launch PRODUCT", "Launch a sandbox environment"
      option :expires_in, type: :string, default: "7d", desc: "Expiration time (e.g., 7d, 24h)"
      option :demo_data, type: :boolean, default: true, desc: "Include demo data"
      def launch(product_id)
        ensure_authenticated!

        puts pastel.bold("Launching sandbox environment")
        puts("Product: #{product_id}")
        puts("Expires: #{options[:expires_in]}")
        puts ""

        spinner = spinner("Creating sandbox...")
        spinner.auto_spin

        response = client.post("/api/v1/sandbox/launch",
                               body: {
                                 product_id: product_id,
                                 expires_in: options[:expires_in],
                                 include_demo_data: options[:demo_data]
                               })

        spinner.success("Sandbox created")

        sandbox = response["sandbox"]

        success "Sandbox environment created"
        info "Sandbox ID: #{sandbox["id"]}"
        info "Organization: #{sandbox["organization_slug"]}"
        info "URL: #{sandbox["url"]}"
        info "Expires: #{sandbox["expires_at"]}"
        puts ""
        info "Login credentials:"
        puts("  Email: #{sandbox["admin_email"]}")
        puts("  Password: #{sandbox["admin_password"]}")
        puts ""
        warning "Save these credentials - they won't be shown again"
      rescue StandardError => e
        handle_error(e)
      end

      desc "teardown SANDBOX_ID", "Teardown a sandbox environment"
      option :force, type: :boolean, desc: "Skip confirmation"
      def teardown(sandbox_id)
        ensure_authenticated!

        response = client.get("/api/v1/sandbox/#{sandbox_id}")
        sandbox = response["sandbox"]

        puts pastel.bold("Teardown Sandbox")
        puts("ID: #{sandbox_id}")
        puts("Product: #{sandbox["product_name"]}")
        puts("Organization: #{sandbox["organization_slug"]}")
        puts ""

        unless options[:force]
          warning "This will permanently delete all data in this sandbox"
          return unless prompt.yes?("Are you sure?")
        end

        spinner = spinner("Tearing down sandbox...")
        spinner.auto_spin

        client.delete("/api/v1/sandbox/#{sandbox_id}")

        spinner.success("Sandbox deleted")
        success "Sandbox environment torn down"
      rescue StandardError => e
        handle_error(e)
      end

      desc "refresh-data SANDBOX_ID", "Refresh demo data in sandbox"
      def refresh_data(sandbox_id)
        ensure_authenticated!

        spinner = spinner("Refreshing sandbox data...")
        spinner.auto_spin

        response = client.post("/api/v1/sandbox/#{sandbox_id}/refresh")

        spinner.success("Data refreshed")

        success "Sandbox data refreshed"
        info "Records refreshed: #{response["refreshed_count"]}"
      rescue StandardError => e
        handle_error(e)
      end

      desc "list", "List all sandbox environments"
      def list
        ensure_authenticated!

        response = client.get("/api/v1/sandbox")

        sandboxes = response["sandboxes"].map do |sandbox|
          {
            id: sandbox["id"],
            product: sandbox["product_name"],
            organization: sandbox["organization_slug"],
            expires: sandbox["expires_at"],
            status: sandbox["status"]
          }
        end

        output_data(sandboxes, headers: %i[id product organization expires status])
      rescue StandardError => e
        handle_error(e)
      end

      desc "extend SANDBOX_ID", "Extend sandbox expiration"
      option :duration, type: :string, required: true, desc: "Additional time (e.g., 7d, 24h)"
      def extend(sandbox_id)
        ensure_authenticated!

        spinner = spinner("Extending sandbox expiration...")
        spinner.auto_spin

        response = client.post("/api/v1/sandbox/#{sandbox_id}/extend",
                               body: { duration: options[:duration] })

        spinner.success("Expiration extended")

        success "Sandbox expiration extended"
        info "New expiration: #{response["expires_at"]}"
      rescue StandardError => e
        handle_error(e)
      end
    end
  end
end
