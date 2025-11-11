# frozen_string_literal: true

require_relative "base"
require "yaml"
require "json"
require "fileutils"
require "pathname"
require "time"

module Kiket
  module Commands
    class Marketplace < Base
      map "onboarding-wizard" => :onboarding_wizard
      map "sync-samples" => :sync_samples
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
          puts pastel.dim("Status: #{installation["status"]}")

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

      option :path, type: :string, desc: "Path to blueprint YAML (defaults to config/marketplace/blueprints/<id>.yml)"
      option :fix, type: :boolean, desc: "Rewrite YAML with canonical formatting"
      desc "validate IDENTIFIER", "Validate a marketplace blueprint definition"
      def validate(identifier)
        path = options[:path] || File.join("config", "marketplace", "blueprints", "#{identifier}.yml")
        unless File.exist?(path)
          error "Blueprint not found at #{path}"
          exit 1
        end

        blueprint = YAML.safe_load_file(path, aliases: true) || {}
        issues = validate_blueprint(identifier, blueprint)

        if options[:fix]
          File.write(path, YAML.dump(blueprint))
          info "Blueprint normalized at #{path}"
        end

        if issues.empty?
          success "Blueprint #{identifier} passed validation"
        else
          error "Blueprint #{identifier} has #{issues.size} issue(s):"
          issues.each { |msg| puts "  • #{msg}" }
          exit 1
        end
      rescue Psych::SyntaxError => e
        error "Invalid YAML: #{e.message}"
        exit 1
      end

      option :name, type: :string, desc: "Display name for the product"
      option :version, type: :string, default: "0.1.0", desc: "Initial version"
      option :description, type: :string, desc: "Short description"
      option :force, type: :boolean, desc: "Overwrite existing blueprint"
      desc "generate TYPE IDENTIFIER", "Generate marketplace assets (bundle)"
      def generate(kind = nil, identifier = nil)
        unless kind == "bundle"
          error "Unknown generator '#{kind}'. Supported types: bundle"
          exit 1
        end

        if identifier.to_s.empty?
          error "Identifier required. Usage: kiket marketplace generate bundle <identifier>"
          exit 1
        end

        name = options[:name] || prompt.ask("Product name:",
                                            default: identifier.split(/[-_]/).map(&:capitalize).join(" "))
        description = options[:description] || prompt.ask("Description:", default: "Describe the value of #{name}")
        version = options[:version]

        blueprint_file = File.join("config", "marketplace", "blueprints", "#{identifier}.yml")
        if File.exist?(blueprint_file) && !options[:force]
          error "Blueprint already exists at #{blueprint_file} (use --force to overwrite)"
          exit 1
        end

        FileUtils.mkdir_p(File.dirname(blueprint_file))
        File.write(blueprint_file, default_blueprint_template(identifier, name, version, description))

        definition_root = File.join("definitions", identifier)
        FileUtils.mkdir_p(File.join(definition_root, "workflows"))
        FileUtils.mkdir_p(File.join(definition_root, "analytics"))
        FileUtils.mkdir_p(File.join(definition_root, "extensions"))
        FileUtils.mkdir_p(File.join(definition_root, "docs"))
        File.write(File.join(definition_root, "README.md"), "# #{name}\n\n#{description}\n")

        success "Bundle skeleton created:"
        info "  Blueprint: #{blueprint_file}"
        info "  Definition root: #{definition_root}"
      end

      option :identifier, type: :string, desc: "Override identifier stored in the manifest"
      option :name, type: :string, desc: "Product name override"
      option :version, type: :string, desc: "Version override"
      option :description, type: :string, desc: "Description override"
      option :categories, type: :array, desc: "Comma-separated categories (e.g. marketing operations)"
      option :pricing_model, type: :string, desc: "Pricing model identifier"
      option :pricing_summary, type: :string, desc: "Short pricing summary"
      option :prerequisites, type: :array, desc: "List of prerequisite setup steps"
      option :published, type: :boolean, desc: "Mark blueprint as published/visible"
      option :sync_blueprint, type: :boolean, default: true, desc: "Also update config/marketplace/blueprints/<id>.yml"
      desc "metadata [PATH]", "Create or update a product metadata manifest (.kiket/product.yaml)"
      def metadata(path = ".")
        definition_root = File.expand_path(path)
        unless Dir.exist?(definition_root)
          error "Directory not found: #{definition_root}"
          exit 1
        end

        blueprint = load_product_metadata(definition_root)
        identifier = options[:identifier] || blueprint&.dig("identifier") || File.basename(definition_root)
        identifier = identifier.to_s.strip
        if identifier.empty?
          error "Identifier required (use --identifier)"
          exit 1
        end

        default_name = default_name_for(identifier)
        blueprint ||= default_blueprint_payload(
          identifier,
          options[:name] || default_name,
          options[:version] || "0.1.0",
          options[:description] || "Describe #{default_name}",
          definition_path: relative_definition_path(definition_root)
        )

        blueprint["identifier"] = identifier
        blueprint["name"] = options[:name] if options[:name]
        blueprint["version"] = options[:version] if options[:version]
        blueprint["description"] = options[:description] if options[:description]
        apply_metadata_overrides!(blueprint, options)

        normalized = normalize_blueprint_payload(blueprint, definition_path: relative_definition_path(definition_root))
        manifest_path = write_metadata_manifest(definition_root, normalized)
        log_info "Metadata manifest written to #{manifest_path}"

        if options[:sync_blueprint]
          blueprint_path = write_blueprint_config(normalized)
          log_info "Blueprint config updated at #{blueprint_path}"
        end

        success "Metadata updated for #{identifier}"
      rescue StandardError => e
        handle_error(e)
      end

      option :destination, type: :string, desc: "Destination directory (defaults to definitions/<identifier>)"
      option :identifier, type: :string, desc: "Override detected identifier"
      option :name, type: :string, desc: "Name override when generating metadata"
      option :version, type: :string, desc: "Version override when generating metadata"
      option :description, type: :string, desc: "Description override when generating metadata"
      option :categories, type: :array, desc: "Categories to set on import"
      option :pricing_model, type: :string, desc: "Pricing model to set on import"
      option :pricing_summary, type: :string, desc: "Pricing summary to set on import"
      option :prerequisites, type: :array, desc: "Prerequisites to set on import"
      option :published, type: :boolean, desc: "Published flag override"
      option :force, type: :boolean, desc: "Overwrite destination if it exists"
      option :metadata_only, type: :boolean, desc: "Only sync metadata, skip copying source files"
      option :sync_blueprint, type: :boolean, default: true, desc: "Also update config/marketplace/blueprints/<id>.yml"
      desc "import SOURCE", "Import a blueprint repo into the local workspace with metadata"
      def import(source = nil)
        if source.to_s.strip.empty?
          error "Source path required"
          exit 1
        end

        source_path = File.expand_path(source)
        unless Dir.exist?(source_path)
          error "Source directory not found: #{source_path}"
          exit 1
        end

        blueprint = load_product_metadata(source_path)
        blueprint ||= discover_blueprint_from_subdir(source_path, options[:identifier])

        identifier = options[:identifier] || blueprint&.dig("identifier") || File.basename(source_path)
        identifier = identifier.to_s.strip
        if identifier.empty?
          error "Unable to determine identifier. Provide --identifier."
          exit 1
        end

        destination = options[:destination]&.strip
        destination ||= File.join("definitions", identifier)
        destination_path = File.expand_path(destination)

        unless options[:metadata_only]
          if File.exist?(destination_path) && File.identical?(source_path, destination_path)
            info "Source and destination are identical; skipping file copy."
          else
            prepare_destination!(destination_path, force: options[:force], empty_ok: true)
            FileUtils.cp_r("#{source_path}/.", destination_path)
          end
        end

        default_name = default_name_for(identifier)
        blueprint ||= default_blueprint_payload(
          identifier,
          options[:name] || default_name,
          options[:version] || "0.1.0",
          options[:description] || "Describe #{default_name}",
          definition_path: relative_definition_path(destination_path)
        )

        blueprint["identifier"] = identifier
        blueprint["name"] = options[:name] if options[:name]
        blueprint["version"] = options[:version] if options[:version]
        blueprint["description"] = options[:description] if options[:description]
        apply_metadata_overrides!(blueprint, options)

        normalized = normalize_blueprint_payload(blueprint, definition_path: relative_definition_path(destination_path))
        manifest_path = write_metadata_manifest(destination_path, normalized)
        log_info "Metadata manifest synced to #{manifest_path}"

        if options[:sync_blueprint]
          blueprint_path = write_blueprint_config(normalized)
          log_info "Blueprint config updated at #{blueprint_path}"
        end

        success "Imported #{identifier} into #{destination_path}"
      rescue StandardError => e
        handle_error(e)
      end

      option :env_file, type: :string, desc: "Path to env file with KIKET_SECRET_* entries"
      desc "secrets SUBCOMMAND INSTALLATION_ID", "Manage marketplace installation secrets (sync currently supported)"
      def secrets(action = nil, installation_id = nil)
        case action
        when "sync"
          sync_installation_secrets(installation_id)
        else
          error "Unknown secrets action '#{action}'. Supported: sync"
          exit 1
        end
      end

      option :expires_in, type: :string, default: "7d", desc: "Expiration (e.g., 7d, 24h)"
      option :demo_data, type: :boolean, default: true, desc: "Seed demo data in sandbox org"
      desc "launch-demo PRODUCT", "Provision a sandbox demo environment for a product"
      def launch_demo(product_id)
        ensure_authenticated!

        spinner = spinner("Provisioning sandbox for #{product_id}...")
        spinner.auto_spin

        response = client.post("/api/v1/sandbox/launch",
                               body: {
                                 product_id: product_id,
                                 expires_in: options[:expires_in],
                                 include_demo_data: options[:demo_data]
                               })

        spinner.success("Sandbox ready")

        sandbox = response["sandbox"]
        success "Sandbox environment created"
        info "Sandbox ID: #{sandbox["id"]}"
        info "Organization: #{sandbox["organization_slug"]}"
        info "URL: #{sandbox["url"]}"
        info "Expires: #{sandbox["expires_at"]}"
        puts ""
        info "Login credentials:"
        puts "  Email: #{sandbox["admin_email"]}"
        puts "  Password: #{sandbox["admin_password"]}"
        warning "\nSave these credentials - they will not be shown again."
      rescue StandardError => e
        handle_error(e)
      end

      option :window_hours, type: :numeric, desc: "Lookback window in hours (default: 24)"
      desc "telemetry SUBCOMMAND", "Marketplace telemetry utilities (report)"
      def telemetry(action = nil)
        case action
        when "report"
          telemetry_report
        else
          error "Unknown telemetry action '#{action}'. Supported: report"
          exit 1
        end
      end

      option :limit, type: :numeric, default: 10, desc: "Number of runs to display (default: 10)"
      option :status, type: :string, desc: "Filter runs by status (queued, running, success, failure, skipped)"
      desc "dbt INSTALLATION", "Show dbt run diagnostics for an installation"
      def dbt(installation_id)
        ensure_authenticated!
        if installation_id.to_s.strip.empty?
          error "Installation ID required. Usage: kiket marketplace dbt <installation_id>"
          exit 1
        end

        params = {}
        limit = options[:limit].to_i
        params[:limit] = limit if limit.positive?
        params[:status] = options[:status] if options[:status]

        spinner = spinner("Fetching dbt runs...")
        spinner.auto_spin
        response = client.get("/api/v1/marketplace/installations/#{installation_id}/dbt_runs", params: params)
        runs = Array(response["runs"])
        spinner.success("Found #{runs.size} run#{'s' unless runs.size == 1}")

        if runs.empty?
          info "No dbt runs recorded for installation #{installation_id}."
          return
        end

        dataset = runs.map do |run|
          {
            id: run["id"],
            status: run["status"],
            command: run["command"],
            queued_at: format_timestamp(run["queued_at"]),
            duration: format_duration(run["duration_ms"]),
            message: summarize_message(run)
          }
        end

        output_data(dataset, headers: %i[id status command queued_at duration message])
      rescue StandardError => e
        handle_error(e)
      end

      desc "onboarding_wizard", "Generate a local blueprint from the marketplace template"
      option :identifier, aliases: "-i", desc: "Blueprint identifier (e.g., marketing-ops)"
      option :name, aliases: "-n", desc: "Product name"
      option :description, aliases: "-d", desc: "Product description"
      option :template, aliases: "-t", default: "sample", desc: "Definition template to copy"
      option :destination, aliases: "-o", desc: "Destination directory"
      option :force, type: :boolean, desc: "Overwrite destination if it exists"
      def onboarding_wizard
        identifier = options[:identifier] || prompt.ask("Product identifier (letters, numbers, dashes):") do |q|
          q.required true
          q.validate(/^[a-z0-9\-]+$/i)
          q.modify :strip, :downcase
        end

        product_name = options[:name] || prompt.ask("Product name:") do |q|
          q.default identifier.split("-").map(&:capitalize).join(" ")
        end

        description = options[:description] || prompt.ask("Product description:") do |q|
          q.default "Describe #{product_name}"
        end

        template_name = (options[:template] || "sample").strip
        template_path = File.join(definitions_root, template_name)
        unless Dir.exist?(template_path)
          error "Template '#{template_name}' not found under #{definitions_root}"
          exit 1
        end

        destination = options[:destination]&.strip
        destination ||= File.join(Dir.pwd, identifier)
        prepare_destination!(destination, force: options[:force])

        FileUtils.cp_r("#{template_path}/.", destination)
        customize_manifest(destination, identifier: identifier, name: product_name, description: description)
        create_onboarding_readme(destination, identifier: identifier, name: product_name)

        success "Blueprint scaffold created at #{destination}"
        puts pastel.blue("ℹ Next steps")
        puts "  • Review #{File.join(destination, '.kiket', 'manifest.yaml')}"
        puts "  • Commit the repo and push to GitHub"
        puts "  • Publish a preview with: kiket extensions publish #{destination} --registry marketplace --dry-run"
      rescue Interrupt
        warning "Wizard cancelled"
      end

      desc "sync_samples", "Copy sample blueprint repositories locally"
      option :destination, aliases: "-o", default: File.join(Dir.pwd, "marketplace-samples"), desc: "Destination folder"
      option :blueprints, aliases: "-b", type: :array, default: %w[sample marketing_ops], desc: "Blueprint directories to copy"
      option :force, type: :boolean, desc: "Overwrite destination if it exists"
      option :with_metadata, type: :boolean, default: true, desc: "Generate product metadata manifests alongside samples"
      def sync_samples
        dest_root = File.expand_path(options[:destination])
        prepare_destination!(dest_root, force: options[:force], empty_ok: true)

        copied = []
        Array(options[:blueprints]).each do |blueprint|
          source = File.join(definitions_root, blueprint)
          unless Dir.exist?(source)
            warning "Blueprint '#{blueprint}' not found; skipping"
            next
          end

          target = File.join(dest_root, blueprint)
          FileUtils.rm_rf(target)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp_r(source, target)
          copied << blueprint

          next unless options[:with_metadata]

          identifier_guess = blueprint.tr("_", "-")
          existing_metadata = load_blueprint_from_repo(identifier_guess) || load_blueprint_from_repo(blueprint)
          metadata_payload = existing_metadata || default_blueprint_payload(
            identifier_guess,
            default_name_for(identifier_guess),
            "0.1.0",
            "Describe #{default_name_for(identifier_guess)}",
            definition_path: relative_definition_path(target)
          )

          normalized = normalize_blueprint_payload(metadata_payload, definition_path: relative_definition_path(target))
          normalized["identifier"] ||= identifier_guess
          write_metadata_manifest(target, normalized)
        end

        if copied.empty?
          warning "No sample blueprints copied"
        else
          success "Copied #{copied.length} blueprint(s) to #{dest_root}"
          copied.each { |bp| puts "  • #{bp}" }
        end
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
          puts "  #{ext_id}: #{keys.join(", ")}"
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
          required = truthy?(ext["required"])

          secrets = Array(ext["secrets"])
          missing = Array(missing_secret_map[ext_id])
          scaffolded = Array(scaffolded_map[ext_id])

          next if missing.empty? && scaffolded.empty?

          secrets.each do |secret|
            key = secret["key"]
            next unless missing.include?(key) || scaffolded.include?(key)

            value = resolve_secret_value(key, env_values, required: required, description: secret["description"])
            next if value.nil?

            store_installation_secret(installation["id"], ext_id, key, value)
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
      rescue StandardError => e
        warning "Failed to read env file #{path}: #{e.message}"
        {}
      end

      def resolve_secret_value(key, env_values, required:, description: nil)
        value = env_values[key] || ENV.fetch(key, nil)
        return value if present?(value)

        if options[:non_interactive]
          warning "Secret #{key} missing in env/ENV; skipping." if required
          return nil
        end

        prompt_text = "Enter value for #{key}"
        prompt_text += " (#{description})" if present?(description)
        prompt.mask("#{prompt_text}:")
      end

      def store_extension_secret(extension_id, key, value)
        payload = { secret: { key: key, value: value } }
        client.post("/api/v1/extensions/#{extension_id}/secrets", body: payload)
      rescue Kiket::ValidationError, Kiket::APIError => e
        if (e.respond_to?(:status) && e.status == 422) || e.message&.match?(/already/i)
          client.patch(
            "/api/v1/extensions/#{extension_id}/secrets/#{key}",
            body: { secret: { value: value } }
          )
        else
          warning "Failed to set secret #{key} for #{extension_id}: #{e.message}"
        end
      end

      def store_installation_secret(installation_id, extension_id, key, value)
        payload = { secret: { extension_id: extension_id, key: key, value: value } }
        client.post("/api/v1/marketplace/installations/#{installation_id}/secrets", body: payload)
      rescue Kiket::ValidationError, Kiket::APIError => e
        if (e.respond_to?(:status) && e.status == 422) || e.message&.match?(/already/i)
          client.patch(
            "/api/v1/marketplace/installations/#{installation_id}/secrets/#{key}",
            body: { secret: { extension_id: extension_id, value: value } }
          )
        else
          warning "Failed to set secret #{key} for #{extension_id} (installation #{installation_id}): #{e.message}"
        end
      end

      def definitions_root
        @definitions_root ||= File.expand_path("../../../../definitions", __dir__)
      end

      def customize_manifest(destination, identifier:, name:, description:)
        manifest_path = File.join(destination, ".kiket", "manifest.yaml")
        FileUtils.mkdir_p(File.dirname(manifest_path))
        manifest = if File.exist?(manifest_path)
                     YAML.safe_load(File.read(manifest_path)) || {}
        else
                     {}
        end
        manifest["identifier"] = identifier
        manifest["name"] = name
        manifest["description"] = description
        manifest["version"] ||= "0.1.0"

        File.write(manifest_path, YAML.dump(manifest))
      end

      def create_onboarding_readme(destination, identifier:, name:)
        path = File.join(destination, "README.md")
        content = <<~MARKDOWN
          # #{name}

          This repository was generated via `kiket marketplace onboarding-wizard` for the blueprint `#{identifier}`.

          ## Next steps

          1. Review `.kiket/manifest.yaml` and customize metadata.
          2. Wire up workflows, extensions, and blueprints inside `definitions/`.
          3. Run:

             ```bash
             kiket extensions lint #{destination}
             kiket extensions publish #{destination} --registry marketplace --dry-run
             ```

          4. Push to GitHub and submit for marketplace review.

          _Generated #{Time.now.utc}._
        MARKDOWN
        File.write(path, content)
      end

      def prepare_destination!(path, force: false, empty_ok: false)
        expanded = File.expand_path(path)
        if Dir.exist?(expanded)
          if force
            FileUtils.rm_rf(expanded)
          elsif !empty_ok && Dir.children(expanded).any?
            error "Destination #{expanded} already exists. Use --force to overwrite."
            exit 1
          end
        end
        FileUtils.mkdir_p(expanded)
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
          details << repo["path"] if present?(repo["path"])
          details << repo["url"] if present?(repo["url"])
          slug = repo["slug"]
          details << "(#{slug})" if slug
          puts "  • #{label} #{details.join(" ")}"
        end
        puts ""
      end

      def truthy?(value)
        case value
        when true then true
        when false, nil then false
        else
          %w[true 1 yes y].include?(value.to_s.strip.downcase)
        end
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
        puts table.render(:unicode, padding: [ 0, 1 ])
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
            line += " (#{secret["description"]})" if present?(secret["description"])
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

      def validate_blueprint(identifier, blueprint)
        issues = []
        required_keys = %w[identifier name version description metadata]
        required_keys.each do |key|
          issues << "Missing #{key}" if blueprint[key].to_s.strip.empty?
        end

        unless blueprint["identifier"].to_s == identifier.to_s
          issues << "Identifier mismatch (expected #{identifier}, found #{blueprint["identifier"]})"
        end

        metadata = blueprint["metadata"] || {}
        issues << "metadata.pricing.model is required" if metadata.dig("pricing", "model").to_s.empty?

        repositories = Array(metadata["repositories"] || blueprint["repositories"])
        repositories.each do |repo|
          next unless repo.is_a?(Hash)
          next unless repo["type"].to_s == "local"

          path = repo["path"]
          issues << "Repository path missing for #{repo.inspect}" if path.to_s.empty?
          issues << "Repository path #{path} not found" if path.present? && !File.exist?(path)
        end

        projects = Array(metadata["projects"] || blueprint["projects"])
        projects.each do |project|
          next unless project.is_a?(Hash)

          issues << "Project key missing" if project["key"].to_s.empty?
          issues << "Project definition_path missing for #{project["key"]}" if project["definition_path"].to_s.empty?
        end

        extensions = Array(metadata["extensions"] || blueprint["extensions"])
        extensions.each do |ext|
          next unless ext.is_a?(Hash)

          issues << "Extension missing extension_id" if ext["extension_id"].to_s.empty?
          Array(ext["secrets"]).each do |secret|
            next unless secret.is_a?(Hash)

            issues << "Secret key missing for extension #{ext["extension_id"]}" if secret["key"].to_s.empty?
          end
        end

        issues
      end

      def default_blueprint_template(identifier, name, version, description)
        YAML.dump(default_blueprint_payload(identifier, name, version, description))
      end

      def default_blueprint_payload(identifier, name, version, description, definition_path: nil)
        repo_path = definition_path || "definitions/#{identifier}"
        project_definition = File.join(repo_path, ".kiket")
        {
          "identifier" => identifier,
          "version" => version,
          "name" => name,
          "description" => description,
          "metadata" => {
            "categories" => [ "custom" ],
            "published" => false,
            "pricing" => {
              "model" => "custom",
              "summary" => "Document pricing details here."
            },
            "repositories" => [
              {
                "type" => "local",
                "path" => repo_path,
                "description" => "Primary definition repository"
              }
            ],
            "projects" => [
              {
                "key" => identifier[0, 8].upcase,
                "name" => "#{name} Project",
                "definition_path" => project_definition,
                "description" => "Primary project for #{name}",
                "repository_url" => "https://github.com/example/#{identifier}"
              }
            ],
            "extensions" => []
          }
        }
      end

      def apply_metadata_overrides!(blueprint, overrides)
        metadata = blueprint["metadata"] ||= {}
        metadata["categories"] = Array(overrides[:categories]) if overrides[:categories]
        metadata["prerequisites"] = Array(overrides[:prerequisites]) if overrides[:prerequisites]
        metadata["published"] = overrides[:published] unless overrides[:published].nil?

        metadata["pricing"] ||= {}
        metadata["pricing"]["model"] = overrides[:pricing_model] if overrides[:pricing_model]
        metadata["pricing"]["summary"] = overrides[:pricing_summary] if overrides[:pricing_summary]
      end

      def product_metadata_path(root)
        File.join(root, ".kiket", "product.yaml")
      end

      def load_product_metadata(root)
        manifest_path = product_metadata_path(root)
        return nil unless File.exist?(manifest_path)

        load_yaml_file(manifest_path)
      end

      def discover_blueprint_from_subdir(root, identifier = nil)
        metadata = nil
        if identifier
          candidate = find_blueprint_config_path(identifier, root: root)
          metadata = load_yaml_file(candidate) if candidate
        end
        return metadata if metadata

        config_dir = blueprint_config_dir(root)
        return nil unless Dir.exist?(config_dir)

        first_file = Dir.glob(File.join(config_dir, "*.yml")).first
        return nil unless first_file

        load_yaml_file(first_file)
      end

      def load_blueprint_from_repo(identifier)
        return nil if identifier.to_s.strip.empty?

        path = find_blueprint_config_path(identifier)
        return nil unless path

        load_yaml_file(path)
      end

      def normalize_blueprint_payload(payload, definition_path: nil)
        data = deep_stringify(payload || {})
        data["metadata"] ||= {}
        data["metadata"]["categories"] = Array(data["metadata"]["categories"]).compact if data["metadata"].key?("categories")
        data["metadata"]["categories"] ||= []
        data["metadata"]["prerequisites"] = Array(data["metadata"]["prerequisites"]).compact if data["metadata"].key?("prerequisites")
        data["metadata"]["prerequisites"] ||= []
        data["metadata"]["repositories"] ||= []
        data["metadata"]["projects"] ||= []
        data["metadata"]["extensions"] ||= []

        if definition_path && data["metadata"]["repositories"].empty?
          data["metadata"]["repositories"] << {
            "type" => "local",
            "path" => definition_path,
            "description" => "Primary definition repository"
          }
        end

        if definition_path && data["metadata"]["projects"].empty?
          data["metadata"]["projects"] << {
            "key" => data["identifier"].to_s[0, 8].upcase,
            "name" => "#{data["name"] || default_name_for(data["identifier"])} Project",
            "definition_path" => File.join(definition_path, ".kiket"),
            "description" => "Primary project for #{data["name"] || default_name_for(data["identifier"])}"
          }
        end

        data
      end

      def write_metadata_manifest(root, payload)
        manifest_path = product_metadata_path(root)
        FileUtils.mkdir_p(File.dirname(manifest_path))
        File.write(manifest_path, YAML.dump(payload))
        manifest_path
      end

      def write_blueprint_config(payload)
        dir = blueprint_config_dir
        FileUtils.mkdir_p(dir)
        path = blueprint_config_path(payload["identifier"])
        File.write(path, YAML.dump(payload))
        path
      end

      def blueprint_config_dir(base_dir = Dir.pwd)
        File.join(base_dir, "config", "marketplace", "blueprints")
      end

      def blueprint_config_path(identifier, base_dir = Dir.pwd)
        sanitized = identifier.to_s.tr("-", "_")
        File.join(blueprint_config_dir(base_dir), "#{sanitized}.yml")
      end

      def find_blueprint_config_path(identifier, root: Dir.pwd)
        dir = blueprint_config_dir(root)
        return nil unless Dir.exist?(dir)

        underscored = File.join(dir, "#{identifier.to_s.tr('-', '_')}.yml")
        dashed = File.join(dir, "#{identifier}.yml")

        return underscored if File.exist?(underscored)
        return dashed if File.exist?(dashed)

        nil
      end

      def relative_definition_path(path)
        Pathname.new(path).expand_path.relative_path_from(Pathname.new(Dir.pwd)).to_s
      rescue ArgumentError
        path
      end

      def default_name_for(identifier)
        return "Product" if identifier.to_s.strip.empty?

        identifier.split(/[-_]/).map { |segment| segment.capitalize }.join(" ")
      end

      def load_yaml_file(path)
        return nil unless path && File.exist?(path)

        YAML.safe_load(File.read(path), aliases: true) || {}
      rescue Psych::SyntaxError => e
        raise "Unable to parse YAML at #{path}: #{e.message}"
      end

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, val), memo|
            memo[key.to_s] = deep_stringify(val)
          end
        when Array
          value.map { |entry| deep_stringify(entry) }
        else
          value
        end
      end

      def log_info(message)
        puts pastel.blue("ℹ #{message}")
      end

      def format_duration(ms)
        return "—" if ms.nil?

        seconds = ms.to_f / 1000.0
        return "#{seconds.round(2)}s" if seconds < 60

        minutes = seconds / 60.0
        "#{minutes.round(1)}m"
      end

      def format_timestamp(value)
        return "—" if value.nil? || value.to_s.strip.empty?

        Time.parse(value).utc.iso8601
      rescue ArgumentError
        value
      end

      def summarize_message(run)
        message = run["error_message"]
        message = run["message"] if message.nil? || message.to_s.strip.empty?
        message = run.dig("metadata", "message") if (message.nil? || message.to_s.strip.empty?) && run["metadata"].is_a?(Hash)
        message.to_s.strip.empty? ? "—" : message.to_s
      end

      def sync_installation_secrets(installation_id)
        ensure_authenticated!

        if installation_id.to_s.empty?
          error "Installation ID required. Usage: kiket marketplace secrets sync <installation_id>"
          exit 1
        end

        response = client.get("/api/v1/marketplace/installations/#{installation_id}")
        installation = response["installation"] || response

        resolved = populate_extension_secrets(installation, options[:env_file])
        refreshed = refresh_installation(installation_id)

        if resolved.empty?
          warning "No secrets updated. Ensure your env file or prompts provide values."
        else
          success "Updated #{resolved.size} secret(s):"
          resolved.each do |entry|
            puts "  #{entry[:extension_id]} → #{entry[:key]}"
          end
        end

        outstanding = refreshed["missing_extension_secrets"] || {}
        if outstanding.any?
          warning "Secrets still missing:"
          outstanding.each do |ext_id, keys|
            puts "  #{ext_id}: #{keys.join(", ")}"
          end
        end
      rescue StandardError => e
        handle_error(e)
      end

      def telemetry_report
        ensure_authenticated!

        params = {}
        if options[:window_hours]
          window = options[:window_hours].to_i
          params[:window_hours] = window if window.positive?
        end

        spinner = spinner("Fetching telemetry data...")
        spinner.auto_spin
        response = client.get("/api/v1/marketplace/telemetry", params: params)
        spinner.success("Telemetry data retrieved")

        total = response["total_events"].to_i
        if total.zero?
          warning "No telemetry recorded in the selected window."
          return
        end

        window_hours = (response["window_seconds"].to_i / 3600.0).round(1)
        puts pastel.bold("\nMarketplace Telemetry")
        puts "Window: last #{window_hours}h"
        puts "Requests: #{total}"
        puts "Errors: #{response["error_count"]} (#{response["error_rate"]}%)"
        puts "Latency: avg #{response["avg_latency_ms"] || '—'}ms · p95 #{response["p95_latency_ms"] || '—'}ms"
        puts ""

        top_extensions = Array(response["top_extensions"])
        if top_extensions.any?
          dataset = top_extensions.map do |entry|
            {
              extension: entry["name"],
              requests: entry["total"],
              error_rate: "#{entry["error_rate"]}%",
              avg_latency_ms: entry["avg_latency_ms"]
            }
          end
          puts pastel.bold("Top extensions")
          output_data(dataset, headers: %i[extension requests error_rate avg_latency_ms])
        else
          info "No extension telemetry to report."
        end

        recent_errors = Array(response["recent_errors"])
        if recent_errors.any?
          puts "\n#{pastel.bold("Recent errors")}"
          recent_errors.each do |entry|
            puts "- #{entry["name"]} (#{entry["extension_id"]}) #{entry["event"]}: #{entry["error_message"]} [#{entry["occurred_at"]}]"
          end
        end
      rescue StandardError => e
        handle_error(e)
      end
    end
  end
end
