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
        spinner.success("Found #{response["products"].size} products")

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

        puts pastel.bold("Product: #{product["name"]}")
        puts pastel.dim("ID: #{product["id"]}")
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
            puts "  • #{ext["name"]}"
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

        puts pastel.bold("\nProduct: #{product["name"]}")
        puts product["description"]
        puts ""

        # Confirm installation
        if !(options[:non_interactive] || options[:dry_run]) && !prompt.yes?("Install #{product["name"]} to #{org}?")
          return
        end

        # Prepare installation payload
        payload = {
          product_id: product_id,
          organization: org,
          dry_run: options[:dry_run],
          skip_demo_data: options[:no_demo_data]
        }

        # Start installation
        spinner = spinner("Installing #{product["name"]}...")
        spinner.auto_spin

        response = client.post("/api/v1/marketplace/installations", body: payload)
        installation = response["installation"]

        if options[:dry_run]
          spinner.success("Dry run completed")
          puts "\nWould install:"
          Array(installation.dig("plan", "actions")).each do |action|
            puts "  • #{action}"
          end
        else
          spinner.success("Installation started")
          success "Installation ID: #{installation["id"]}"
          info "Status: #{installation["status"]}"

          handle_post_install(installation, options[:env_file])
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

        puts pastel.bold("\nUpgrade: #{installation["product_name"]}")
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
          puts "  #{icon} #{change["description"]}"
        end
        puts ""

        return if !options[:auto_approve] && !prompt.yes?("Proceed with upgrade?")

        spinner = spinner("Starting upgrade...")
        spinner.auto_spin
        response = client.post("/api/v1/marketplace/installations/#{installation_id}/upgrade",
                               body: { version: target_version })
        spinner.success("Upgrade started")

        success "Upgrade job ID: #{response["job_id"]}"
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

        puts pastel.bold("\nUninstall: #{installation["product_name"]}")
        puts "Installation ID: #{installation_id}"
        puts ""

        unless options[:force]
          warning "This will remove all workflows, extensions, and projects associated with this product"
          warning "Data will be #{options[:preserve_data] ? "preserved" : "permanently deleted"}"
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

          puts pastel.bold("Installation: #{installation["product_name"] || installation["product_id"]}")
          puts "ID: #{installation["id"]}"
          puts "Status: #{format_status(installation["status"])}"
          puts "Version: #{installation["product_version"]}"
          puts "Installed: #{installation["installed_at"]}"
          puts ""

          if installation["health"]
            puts pastel.bold("Health:")
            installation["health"].each do |check, status|
              icon = status["ok"] ? pastel.green("✓") : pastel.red("✗")
              puts "  #{icon} #{check}: #{status["message"]}"
            end
            puts ""
          end

          display_repositories(installation)
          display_projects(installation)
          display_extensions(installation)
        else
          # List all installations for org
          unless org
            error "Organization required. Use --org flag or set default_org"
            exit 1
          end

          response = client.get("/api/v1/marketplace/installations", params: { organization: org })
          installations = response["installations"].map do |inst|
            issues = []
            issues << "extensions" if Array(inst["missing_extensions"]).any?
            missing_secret_map = inst["missing_extension_secrets"] || {}
            issues << "secrets" if missing_secret_map.any?
            {
              id: inst["id"],
              product: inst["product_name"] || inst["product"],
              version: inst["product_version"],
              status: inst["status"],
              installed: inst["installed_at"],
              issues: issues.join(", ")
            }
          end

          output_data(installations, headers: %i[id product version status installed issues])
        end
      rescue StandardError => e
        handle_error(e)
      end

      private

      def handle_post_install(installation, env_file)
        resolved = populate_extension_secrets(installation, env_file)
        refreshed = refresh_installation(installation["id"])

        unless resolved.empty?
          puts pastel.green("\nSecrets updated:")
          resolved.each do |entry|
            puts "  #{entry[:extension_id]} → #{entry[:key]}"
          end
          puts ""
        end

        display_repositories(refreshed)
        display_projects(refreshed)
        display_extensions(refreshed)

        outstanding = refreshed["missing_extension_secrets"] || {}
        return if outstanding.empty?

        puts pastel.yellow("Remaining secrets to configure:")
        outstanding.each do |ext_id, keys|
          puts "  #{ext_id}: #{keys.join(', ')}"
        end
        puts pastel.dim("Use `kiket secrets set <KEY> --extension <EXT_ID>` or rerun the install with --env-file.")
      rescue StandardError => e
        warning "Post-installation checks failed: #{e.message}"
      end

      def populate_extension_secrets(installation, env_file)
        env_values = load_env_file(env_file)
        resolved = []

        extensions = Array(installation["extensions"])
        missing_secret_map = installation["missing_extension_secrets"] || {}
        scaffolded_map = installation["scaffolded_extension_secrets"] || {}

        extensions.each do |ext|
          next unless ext["present"]
          ext_id = ext["extension_id"]
          required = ActiveModel::Type::Boolean.new.cast(ext["required"])

          secrets = Array(ext["secrets"])
          missing = Array(missing_secret_map[ext_id])
          scaffolded = Array(scaffolded_map[ext_id])

          next if missing.empty? && scaffolded.empty?

          secrets.each do |secret|
            key = secret["key"]
            next unless missing.include?(key) || scaffolded.include?(key)

            value = resolve_secret_value(key, env_values, required: required, description: secret["description"])
            next if value.nil?

            store_extension_secret(ext_id, key, value)
            resolved << { extension_id: ext_id, key: key }
          end
        end

        resolved
      end

      def refresh_installation(installation_id)
        response = client.post("/api/v1/marketplace/installations/#{installation_id}/refresh")
        response["installation"] || response
      rescue StandardError => e
        warning "Unable to refresh installation metadata: #{e.message}"
        {}
      end

      def load_env_file(path)
        return {} if path.nil? || path.strip.empty?
        unless File.exist?(path)
          warning "Env file #{path} not found"
          return {}
        end

        File.readlines(path).each_with_object({}) do |line, acc|
          line = line.strip
          next if line.empty? || line.start_with?("#")
          key, value = line.split("=", 2)
          next if key.nil? || value.nil?
          acc[key.strip] = value.strip
        end
      rescue => e
        warning "Failed to read env file #{path}: #{e.message}"
        {}
      end

      def resolve_secret_value(key, env_values, required:, description: nil)
        value = env_values[key] || ENV[key]
        return value if value.present?

        if options[:non_interactive]
          warning "Secret #{key} missing in env/ENV; skipping." if required
          return nil
        end

        prompt_text = "Enter value for #{key}"
        prompt_text += " (#{description})" if description.present?
        prompt.mask("#{prompt_text}:")
      end

      def store_extension_secret(extension_id, key, value)
        payload = { secret: { key: key, value: value } }
        client.post("/api/v1/extensions/#{extension_id}/secrets", body: payload)
      rescue Kiket::ValidationError, Kiket::APIError => e
        if e.respond_to?(:status) && e.status == 422 || e.message&.match?(/already/i)
          client.patch(
            "/api/v1/extensions/#{extension_id}/secrets/#{key}",
            body: { secret: { value: value } }
          )
        else
          warning "Failed to set secret #{key} for #{extension_id}: #{e.message}"
        end
      end

      def format_status(status)
        case status
        when "active" then pastel.green(status)
        when "installing", "upgrading" then pastel.yellow(status)
        when "failed", "deprecated" then pastel.red(status)
        else status
        end
      end

      def display_repositories(installation)
        repos = Array(installation["repositories"])
        return if repos.empty?

        puts pastel.bold("Repositories:")
        repos.each do |repo|
          type = repo["type"] || "local"
          label = "[#{type}]"
          details = []
          details << repo["path"] if repo["path"].present?
          details << repo["url"] if repo["url"].present?
          slug = repo["slug"]
          details << "(#{slug})" if slug
          puts "  • #{label} #{details.join(" ")}"
        end
        puts ""
      end

      def display_projects(installation)
        projects = Array(installation["projects"])
        return if projects.empty?

        rows = projects.map do |project|
          [
            project["key"] || "-",
            project["name"],
            project["github_repo_url"] || "-"
          ]
        end

        table = TTY::Table.new(%w[key name repository], rows)
        puts pastel.bold("Projects:")
        puts table.render(:unicode, padding: [0, 1])
        puts ""
      end

      def display_extensions(installation)
        extensions = Array(installation["extensions"])
        return if extensions.empty?

        puts pastel.bold("Extensions:")

        extensions.each do |ext|
          status_label = if ext["present"]
                           pastel.green("installed")
                         else
                           pastel.red("missing")
                         end

          requirement = ext["required"] ? pastel.red("required") : pastel.dim("optional")
          puts "  • #{ext["extension_id"]} (#{ext["name"]}) - #{status_label}, #{requirement}"

          secrets = Array(ext["secrets"])
          missing = Array(ext["missing_secrets"])
          scaffolded = Array(ext["scaffolded_secrets"])

          next if secrets.empty?

          secrets.each do |secret|
            key = secret["key"]
            line = "      - #{key}"
            line += " (#{secret["description"]})" if secret["description"].present?
            line += if missing.include?(key)
                      " #{pastel.yellow("[missing]")}"
                    else
                      " #{pastel.green("[configured]")}"
                    end
            line += pastel.cyan(" [placeholder]") if scaffolded.include?(key)
            puts line
          end
        end

        missing_exts = Array(installation["missing_extensions"])
        puts pastel.red("\nMissing extensions: #{missing_exts.join(", ")}") if missing_exts.any?

        missing_secret_map = installation["missing_extension_secrets"] || {}
        if missing_secret_map.any?
          puts pastel.yellow("\nSecrets pending configuration:")
          missing_secret_map.each do |ext_id, keys|
            puts "  #{ext_id}: #{keys.join(", ")}"
          end
          puts pastel.dim("Use `kiket secrets set <KEY> --extension <EXT>` to update values.")
        end

        scaffolded_map = installation["scaffolded_extension_secrets"] || {}
        if scaffolded_map.any?
          puts pastel.cyan("\nPlaceholder secrets created:")
          scaffolded_map.each do |ext_id, keys|
            puts "  #{ext_id}: #{keys.join(", ")}"
          end
        end

        puts ""
      end
    end
  end
end
