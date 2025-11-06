# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Marketplace < Base
      desc "list", "List available marketplace products"
      option :all, type: :boolean, desc: "Show all versions"
      def list
        ensure_authenticated!

        spinner = spinner("Fetching marketplace products...")
        spinner.auto_spin

        response = client.get("/api/v1/marketplace/products", params: { all: options[:all] })
        spinner.success("Found #{response['products'].size} products")

        products = response["products"].map do |product|
          {
            id: product["id"],
            name: product["name"],
            version: product["version"],
            description: product["description"]&.slice(0, 60),
            pricing: product["pricing_model"]
          }
        end

        output_data(products, headers: %i[id name version description pricing])
      rescue StandardError => e
        handle_error(e)
      end

      desc "info PRODUCT", "Show detailed information about a product"
      def info(product_id)
        ensure_authenticated!

        response = client.get("/api/v1/marketplace/products/#{product_id}")
        product = response["product"]

        puts pastel.bold("Product: #{product['name']}")
        puts pastel.dim("ID: #{product['id']}")
        puts ""
        puts product["description"]
        puts ""
        puts pastel.bold("Version: ") + product["version"]
        puts pastel.bold("Pricing: ") + product["pricing_model"]
        puts ""

        if product["prerequisites"]&.any?
          puts pastel.bold("Prerequisites:")
          product["prerequisites"].each do |prereq|
            puts "  • #{prereq}"
          end
          puts ""
        end

        if product["extensions"]&.any?
          puts pastel.bold("Included Extensions:")
          product["extensions"].each do |ext|
            puts "  • #{ext['name']}"
          end
          puts ""
        end

        if product["workflows"]&.any?
          puts pastel.bold("Workflows:")
          product["workflows"].each do |workflow|
            puts "  • #{workflow}"
          end
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "install PRODUCT", "Install a marketplace product"
      option :dry_run, type: :boolean, desc: "Show what would be installed without actually installing"
      option :env_file, type: :string, desc: "Path to environment file for secrets"
      option :no_demo_data, type: :boolean, desc: "Skip demo data seeding"
      option :non_interactive, type: :boolean, desc: "Run without prompts"
      def install(product_id)
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required. Use --org flag or set default_org in config"
          exit 1
        end

        # Fetch product details
        spinner = spinner("Fetching product details...")
        spinner.auto_spin
        product = client.get("/api/v1/marketplace/products/#{product_id}")["product"]
        spinner.success("Product loaded")

        puts pastel.bold("\nProduct: #{product['name']}")
        puts product["description"]
        puts ""

        # Confirm installation
        unless options[:non_interactive] || options[:dry_run]
          return unless prompt.yes?("Install #{product['name']} to #{org}?")
        end

        # Prepare installation payload
        payload = {
          product_id: product_id,
          organization: org,
          dry_run: options[:dry_run],
          skip_demo_data: options[:no_demo_data]
        }

        # Start installation
        spinner = spinner("Installing #{product['name']}...")
        spinner.auto_spin

        response = client.post("/api/v1/marketplace/installations", body: payload)
        installation = response["installation"]

        if options[:dry_run]
          spinner.success("Dry run completed")
          puts "\nWould install:"
          installation["plan"]["actions"].each do |action|
            puts "  • #{action}"
          end
        else
          spinner.success("Installation started")
          success "Installation ID: #{installation['id']}"
          info "Status: #{installation['status']}"
          info "Run 'kiket marketplace status #{installation['id']}' to check progress"
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "upgrade INSTALLATION", "Upgrade a product installation"
      option :version, type: :string, desc: "Target version (defaults to latest)"
      option :auto_approve, type: :boolean, desc: "Skip approval prompts"
      def upgrade(installation_id)
        ensure_authenticated!

        spinner = spinner("Fetching installation details...")
        spinner.auto_spin
        response = client.get("/api/v1/marketplace/installations/#{installation_id}")
        installation = response["installation"]
        spinner.success("Installation loaded")

        current_version = installation["product_version"]
        target_version = options[:version] || "latest"

        puts pastel.bold("\nUpgrade: #{installation['product_name']}")
        puts "Current version: #{current_version}"
        puts "Target version: #{target_version}"
        puts ""

        # Fetch upgrade preview
        spinner = spinner("Generating upgrade preview...")
        spinner.auto_spin
        preview = client.post("/api/v1/marketplace/installations/#{installation_id}/upgrade/preview",
                               body: { version: target_version })
        spinner.success("Preview ready")

        puts pastel.bold("Changes:")
        preview["changes"].each do |change|
          icon = case change["type"]
                 when "add" then pastel.green("+")
                 when "remove" then pastel.red("-")
                 when "modify" then pastel.yellow("~")
                 else "•"
                 end
          puts "  #{icon} #{change['description']}"
        end
        puts ""

        unless options[:auto_approve]
          return unless prompt.yes?("Proceed with upgrade?")
        end

        spinner = spinner("Starting upgrade...")
        spinner.auto_spin
        response = client.post("/api/v1/marketplace/installations/#{installation_id}/upgrade",
                                body: { version: target_version })
        spinner.success("Upgrade started")

        success "Upgrade job ID: #{response['job_id']}"
        info "Monitor with: kiket marketplace status #{installation_id}"
      rescue StandardError => e
        handle_error(e)
      end

      desc "uninstall INSTALLATION", "Uninstall a product"
      option :force, type: :boolean, desc: "Force uninstall without confirmation"
      option :preserve_data, type: :boolean, desc: "Keep data after uninstall"
      def uninstall(installation_id)
        ensure_authenticated!

        response = client.get("/api/v1/marketplace/installations/#{installation_id}")
        installation = response["installation"]

        puts pastel.bold("\nUninstall: #{installation['product_name']}")
        puts "Installation ID: #{installation_id}"
        puts ""

        unless options[:force]
          warning "This will remove all workflows, extensions, and projects associated with this product"
          warning "Data will be #{options[:preserve_data] ? 'preserved' : 'permanently deleted'}"
          return unless prompt.yes?("Are you sure you want to uninstall?")
        end

        spinner = spinner("Uninstalling...")
        spinner.auto_spin
        client.delete("/api/v1/marketplace/installations/#{installation_id}",
                      params: { preserve_data: options[:preserve_data] })
        spinner.success("Uninstalled")

        success "Product uninstalled successfully"
      rescue StandardError => e
        handle_error(e)
      end

      desc "status [INSTALLATION]", "Show installation status"
      def status(installation_id = nil)
        ensure_authenticated!
        org = organization

        if installation_id
          # Show specific installation
          response = client.get("/api/v1/marketplace/installations/#{installation_id}")
          installation = response["installation"]

          puts pastel.bold("Installation: #{installation['product_name']}")
          puts "ID: #{installation['id']}"
          puts "Status: #{format_status(installation['status'])}"
          puts "Version: #{installation['product_version']}"
          puts "Installed: #{installation['installed_at']}"
          puts ""

          if installation["health"]
            puts pastel.bold("Health:")
            installation["health"].each do |check, status|
              icon = status["ok"] ? pastel.green("✓") : pastel.red("✗")
              puts "  #{icon} #{check}: #{status['message']}"
            end
          end
        else
          # List all installations for org
          unless org
            error "Organization required. Use --org flag or set default_org"
            exit 1
          end

          response = client.get("/api/v1/marketplace/installations", params: { organization: org })
          installations = response["installations"].map do |inst|
            {
              id: inst["id"],
              product: inst["product_name"],
              version: inst["product_version"],
              status: inst["status"],
              installed: inst["installed_at"]
            }
          end

          output_data(installations, headers: %i[id product version status installed])
        end
      rescue StandardError => e
        handle_error(e)
      end

      private

      def format_status(status)
        case status
        when "active" then pastel.green(status)
        when "installing", "upgrading" then pastel.yellow(status)
        when "failed", "deprecated" then pastel.red(status)
        else status
        end
      end
    end
  end
end
