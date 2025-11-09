# frozen_string_literal: true

require_relative "base"
require "fileutils"
require "zlib"
require "rubygems/package"
require "json"
require "net/http"
require "uri"
require "openssl"
require "securerandom"

module Kiket
  module Commands
    class Extensions < Base
      REPLAY_TEMPLATES = {
        "before_transition" => {
          "event" => "workflow.before_transition",
          "event_type" => "before_transition",
          "issue" => {
            "id" => 42,
            "status" => "in_progress",
            "project_id" => 7,
            "organization_id" => 3
          },
          "transition" => {
            "from" => "in_progress",
            "to" => "review",
            "performed_by" => "alex@example.com"
          }
        },
        "after_transition" => {
          "event" => "workflow.after_transition",
          "event_type" => "after_transition",
          "issue" => {
            "id" => 57,
            "status" => "review",
            "project_id" => 7,
            "organization_id" => 3
          },
          "transition" => {
            "from" => "in_progress",
            "to" => "review",
            "performed_by" => "casey@example.com"
          }
        },
        "issue_created" => {
          "event" => "issue.created",
          "event_type" => "issue_created",
          "issue" => {
            "id" => 99,
            "title" => "Customer onboarding",
            "status" => "todo",
            "project_id" => 11,
            "organization_id" => 5
          }
        }
      }.freeze

      map(
        "custom-data:list" => :custom_data_list,
        "custom-data:get" => :custom_data_get,
        "custom-data:create" => :custom_data_create,
        "custom-data:update" => :custom_data_update,
        "custom-data:delete" => :custom_data_delete,
        "secrets:pull" => :extension_secrets_pull,
        "secrets:push" => :extension_secrets_push
      )
      desc "scaffold NAME", "Generate a new extension project"
      option :sdk, type: :string, default: "python", desc: "SDK language (python, node, ruby)"
      option :manifest, type: :boolean, desc: "Generate manifest only"
      option :template, type: :string, desc: "Template type (webhook_guard, outbound_integration, notification_pack)"
      option :extension_id, type: :string, desc: "Override extension ID in manifest"
      option :ci, type: :boolean, default: true, desc: "Include GitHub Actions workflow"
      option :tests, type: :boolean, default: true, desc: "Include example tests"
      option :replay, type: :boolean, default: true, desc: "Generate replay samples"
      option :force, type: :boolean, desc: "Overwrite existing directory"
      def scaffold(name)
        ensure_authenticated!

        template_type = options[:template] || prompt.select("Select extension template:", %w[
                                                              webhook_guard
                                                              outbound_integration
                                                              notification_pack
                                                              custom
                                                            ])

        sdk = options[:sdk].to_s.downcase
        sdk = "node" if sdk == "typescript"
        dir = File.join(Dir.pwd, name)

        if File.exist?(dir)
          if options[:force]
            FileUtils.rm_rf(dir)
          else
            error "Directory #{name} already exists (use --force to overwrite)"
            exit 1
          end
        end

        unless %w[python node ruby].include?(sdk)
          error "Unsupported SDK '#{sdk}'. Supported values: python, node, ruby."
          exit 1
        end

        spinner = spinner("Generating extension project...")
        spinner.auto_spin

        FileUtils.mkdir_p(dir)

        # Generate manifest
        generate_manifest(
          dir,
          name,
          template_type,
          extension_id: options[:extension_id]
        )

        # Generate SDK-specific files
        case sdk
        when "python"
          generate_python_extension(dir, name, template_type)
        when "node"
          generate_typescript_extension(dir, name, template_type)
        when "ruby"
          generate_ruby_extension(dir, name, template_type)
        end

        # Generate common files
        generate_readme(dir, name, sdk)
        generate_gitignore(dir)
        generate_tests(dir, sdk, template_type, name) if options[:tests]
        generate_github_actions(dir, sdk) if options[:ci]
        generate_env_example(dir)
        generate_replay_samples(dir, template_type) if options[:replay]

        spinner.success("Extension project created")

        success "Extension '#{name}' created at #{dir}"
        info "Next steps:"
        info "  cd #{name}"
        info "  # Edit .kiket/manifest.yaml"
        info "  kiket extensions lint"
        info "  kiket extensions test"
      rescue StandardError => e
        handle_error(e)
      end

      desc "init [PATH]", "Create or refresh .kiket/manifest.yaml in an existing project"
      option :extension_id, type: :string, desc: "Extension ID to use in the manifest"
      option :name, type: :string, desc: "Extension display name"
      option :template, type: :string, default: "custom", desc: "Template type for hooks"
      def init(path = ".")
        dir = File.expand_path(path)
        unless File.directory?(dir)
          error "Directory #{dir} not found"
          exit 1
        end

        name = options[:name] || File.basename(dir)
        generate_manifest(dir, name, options[:template], extension_id: options[:extension_id])
        success "Manifest created at #{File.join(dir, '.kiket/manifest.yaml')}"
      rescue StandardError => e
        handle_error(e)
      end

      desc "lint [PATH]", "Lint extension manifest and code"
      option :fix, type: :boolean, desc: "Auto-fix issues where possible"
      def lint(path = ".")
        manifest_path = File.join(path, ".kiket", "manifest.yaml")

        unless File.exist?(manifest_path)
          error "No manifest.yaml found at #{manifest_path}"
          exit 1
        end

        spinner = spinner("Linting extension...")
        spinner.auto_spin

        # Validate manifest locally
        require "yaml"
        manifest = YAML.load_file(manifest_path)

        errors = []
        warnings = []

        # Required fields
        errors << "Missing extension.id" unless manifest.dig("extension", "id")
        errors << "Missing extension.name" unless manifest.dig("extension", "name")
        errors << "Missing delivery configuration" unless manifest["delivery"]

        # Validate delivery configuration
        if manifest["delivery"]
          delivery_type = manifest.dig("delivery", "type")
          errors << "Invalid delivery type" unless %w[http internal].include?(delivery_type)

          if delivery_type == "http"
            errors << "Missing delivery.url" unless manifest.dig("delivery", "url")
            timeout = manifest.dig("delivery", "timeout")
            errors << "Timeout must be between 100 and 10000ms" if timeout && (timeout < 100 || timeout > 10_000)
          end
        end

        # Check for test files
        test_dirs = Dir.glob("#{path}/{test,spec,tests}").select { |f| File.directory?(f) }
        warnings << "No test directory found" if test_dirs.empty?

        # Check for README
        warnings << "No README.md found" unless File.exist?(File.join(path, "README.md"))

        custom_data_results = validate_custom_data_assets(path, manifest)
        errors.concat(custom_data_results[:errors])
        warnings.concat(custom_data_results[:warnings])

        spinner.stop

        if errors.any?
          error "Manifest validation failed:"
          errors.each { |err| puts "  ✗ #{err}" }
          exit 1
        end

        if warnings.any?
          warning "Warnings:"
          warnings.each { |warn| puts "  ⚠ #{warn}" }
        end

        success "Extension manifest is valid"

        # Run SDK-specific linting
        if File.exist?(File.join(path, "requirements.txt"))
          info "Running Python linting..."
          cmd = "cd #{path} && ruff check ."
          cmd += " --fix" if options[:fix]
          system(cmd)
        elsif File.exist?(File.join(path, "package.json"))
          info "Running TypeScript linting..."
          cmd = "cd #{path} && npm run lint"
          cmd += " -- --fix" if options[:fix]
          system(cmd)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "test [PATH]", "Run extension tests"
      option :watch, type: :boolean, desc: "Watch for changes"
      def test(path = ".")
        if File.exist?(File.join(path, "requirements.txt"))
          info "Running Python tests..."
          cmd = "cd #{path} && pytest"
          cmd += " --watch" if options[:watch]
          system(cmd)
        elsif File.exist?(File.join(path, "package.json"))
          info "Running TypeScript tests..."
          cmd = "cd #{path} && npm test"
          cmd += " -- --watch" if options[:watch]
          system(cmd)
        elsif File.exist?(File.join(path, "Gemfile"))
          info "Running Ruby tests..."
          cmd = "cd #{path} && bundle exec rspec"
          system(cmd)
        else
          error "No test framework detected"
          exit 1
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "replay", "Replay a recorded payload against a local extension endpoint"
      option :payload, type: :string, desc: "Path to JSON payload (defaults to STDIN)"
      option :template, type: :string, desc: "Built-in template (#{REPLAY_TEMPLATES.keys.join(', ')})"
      option :url, type: :string, default: "http://localhost:8080/webhook", desc: "Destination URL"
      option :method, type: :string, default: "POST", desc: "HTTP method"
      option :header, type: :array, desc: "Custom headers (KEY=VALUE)"
      option :env_file, type: :string, desc: "Env file for injecting secrets"
      option :secret_prefix, type: :string, default: "KIKET_SECRET_", desc: "ENV prefix for secrets"
      option :signing_secret, type: :string, desc: "Signing secret to compute X-Kiket-Signature"
      def replay
        payload = build_replay_payload(options)
        body = JSON.pretty_generate(payload)
        headers = { "Content-Type" => "application/json", "Accept" => "application/json" }
        Array(options[:header]).each do |entry|
          key, value = entry.split("=", 2)
          headers[key] = value if key && value
        end

        if present?(options[:signing_secret])
          signature = OpenSSL::HMAC.hexdigest("SHA256", options[:signing_secret], body)
          headers["X-Kiket-Signature"] = signature
        end

        response = perform_replay_request(options[:url], options[:method], body, headers)
        code = response.code.to_i
        color = code >= 400 ? :red : :green
        puts pastel.public_send(color, "HTTP #{code}")
        puts response.body if response.body&.strip&.length&.positive?
        exit 1 if code >= 400
      rescue JSON::ParserError => e
        error "Invalid JSON payload: #{e.message}"
        exit 1
      rescue StandardError => e
        handle_error(e)
      end

      desc "validate [PATH]", "Validate extension for publishing"
      def validate(path = ".")
        ensure_authenticated!

        manifest_path = File.join(path, ".kiket", "manifest.yaml")

        unless File.exist?(manifest_path)
          error "No manifest.yaml found"
          exit 1
        end

        # Run lint
        invoke :lint, [path]

        # Check for git repository
        unless Dir.exist?(File.join(path, ".git"))
          error "Extension must be in a git repository"
          info "Initialize with: git init"
          exit 1
        end

        # Check for remote
        require "open3"
        stdout, _, status = Open3.capture3("git -C #{path} remote get-url origin")

        unless status.success?
          error "No git remote 'origin' configured"
          info "Add remote with: git remote add origin https://github.com/username/repo.git"
          exit 1
        end

        remote_url = stdout.strip

        unless remote_url.match?(/github\.com/)
          error "Remote must be a GitHub repository"
          info "Current remote: #{remote_url}"
          exit 1
        end

        # Check for uncommitted changes
        stdout, = Open3.capture3("git -C #{path} status --porcelain")

        if stdout.strip.length.positive?
          warning "Uncommitted changes detected"
          info "Commit changes before publishing"
        end

        success "Extension validation passed"
        info "Repository: #{remote_url}"
      rescue StandardError => e
        handle_error(e)
      end

      desc "package [PATH]", "Create a distributable tarball for an extension"
      option :output, type: :string, desc: "Output directory (defaults to ./dist)"
      def package(path = ".")
        manifest_path = File.join(path, ".kiket", "manifest.yaml")
        unless File.exist?(manifest_path)
          error "No manifest.yaml found at #{manifest_path}"
          exit 1
        end

        manifest = YAML.safe_load_file(manifest_path)
        extension_id = manifest.dig("extension", "id") || manifest["extension_id"]
        version = manifest.dig("extension", "version") || manifest["version"]

        if extension_id.to_s.empty? || version.to_s.empty?
          error "Manifest must include extension.id and version"
          exit 1
        end

        slug = extension_id.tr(".", "-")
        output_dir = options[:output] || File.join(path, "dist")
        FileUtils.mkdir_p(output_dir)
        archive_path = File.join(output_dir, "#{slug}-#{version}.tar.gz")

        create_tarball(path, archive_path)

        success "Package created"
        info "Archive: #{archive_path}"
      rescue Psych::SyntaxError => e
        error "Invalid manifest: #{e.message}"
        exit 1
      end

      desc "publish [PATH]", "Publish extension to marketplace via GitHub"
      option :registry, type: :string, default: "marketplace", desc: "Registry name"
      option :dry_run, type: :boolean, desc: "Validate without publishing"
      option :ref, type: :string, desc: "Git ref (branch/tag) to publish (defaults to current branch)"
      def publish(path = ".")
        ensure_authenticated!

        manifest_path = File.join(path, ".kiket", "manifest.yaml")

        unless File.exist?(manifest_path)
          error "No manifest.yaml found"
          exit 1
        end

        # Validate extension
        invoke :validate, [path]

        # Run tests
        info "Running tests before publish..."
        invoke :test, [path]

        require "yaml"
        require "open3"
        manifest = YAML.load_file(manifest_path)

        # Get git information
        remote_url, = Open3.capture2("git -C #{path} remote get-url origin")
        remote_url = remote_url.strip

        current_branch, = Open3.capture2("git -C #{path} rev-parse --abbrev-ref HEAD")
        current_branch = current_branch.strip

        git_ref = options[:ref] || current_branch

        commit_sha, = Open3.capture2("git -C #{path} rev-parse #{git_ref}")
        commit_sha = commit_sha.strip[0..7]

        puts pastel.bold("\nPublish Extension:")
        puts "  ID: #{manifest.dig("extension", "id")}"
        puts "  Name: #{manifest.dig("extension", "name")}"
        puts "  Version: #{manifest.dig("extension", "version")}"
        puts "  Repository: #{remote_url}"
        puts "  Ref: #{git_ref}"
        puts "  Commit: #{commit_sha}"
        puts ""

        if options[:dry_run]
          info "Dry run - skipping actual publish"
          return
        end

        return unless prompt.yes?("Publish to #{options[:registry]}?")

        spinner = spinner("Publishing extension...")
        spinner.auto_spin

        # Publish via GitHub repository reference
        response = client.post("/api/v1/extensions/registry/#{options[:registry]}/publish",
                               body: {
                                 manifest: manifest,
                                 repository: {
                                   url: remote_url,
                                   ref: git_ref,
                                   commit_sha: commit_sha
                                 }
                               })

        spinner.success("Published")
        success "Extension published successfully"
        info "Registry: #{options[:registry]}"
        info "Version: #{response["version"]}"
        info "Extension ID: #{response["extension_id"]}" if response["extension_id"]
      rescue StandardError => e
        handle_error(e)
      end

      desc "doctor [PATH]", "Diagnose extension issues"
      option :verbose, type: :boolean, desc: "Show detailed diagnostic info"
      def doctor(path = ".")
        puts pastel.bold("Extension Health Check\n")

        checks = []

        # Check manifest
        manifest_path = File.join(path, ".kiket", "manifest.yaml")
        if File.exist?(manifest_path)
          checks << { name: "Manifest file", status: :ok, message: "Found" }

          begin
            require "yaml"
            manifest = YAML.load_file(manifest_path)
            checks << { name: "Manifest syntax", status: :ok, message: "Valid YAML" }

            checks << if manifest.dig("extension", "id")
                        { name: "Extension ID", status: :ok, message: manifest.dig("extension", "id") }
                      else
                        { name: "Extension ID", status: :error, message: "Missing" }
                      end
          rescue StandardError => e
            checks << { name: "Manifest syntax", status: :error, message: e.message }
          end
        else
          checks << { name: "Manifest file", status: :error, message: "Not found" }
        end

        # Check for SDK
        if File.exist?(File.join(path, "requirements.txt"))
          checks << { name: "SDK", status: :ok, message: "Python detected" }

          # Check SDK version
          if File.exist?(File.join(path, ".python-version"))
            version = File.read(File.join(path, ".python-version")).strip
            checks << { name: "Python version", status: :ok, message: version }
          end
        elsif File.exist?(File.join(path, "package.json"))
          checks << { name: "SDK", status: :ok, message: "TypeScript/JavaScript detected" }
        elsif File.exist?(File.join(path, "Gemfile"))
          checks << { name: "SDK", status: :ok, message: "Ruby detected" }
        else
          checks << { name: "SDK", status: :warning, message: "No SDK detected" }
        end

        # Check for tests
        test_files = Dir.glob("#{path}/{test,spec,tests}/**/*_test.{py,rb,js,ts}") +
                     Dir.glob("#{path}/{test,spec,tests}/**/*_spec.{py,rb,js,ts}")
        checks << if test_files.any?
                    { name: "Tests", status: :ok, message: "#{test_files.size} test files found" }
                  else
                    { name: "Tests", status: :warning, message: "No test files found" }
                  end

        # Check for documentation
        checks << if File.exist?(File.join(path, "README.md"))
                    { name: "Documentation", status: :ok, message: "README.md present" }
                  else
                    { name: "Documentation", status: :warning, message: "No README.md" }
                  end

        # Display results
        checks.each do |check|
          icon = case check[:status]
                 when :ok then pastel.green("✓")
                 when :warning then pastel.yellow("⚠")
                 when :error then pastel.red("✗")
                 end
          puts "#{icon} #{check[:name]}: #{check[:message]}"
        end

        puts ""
        errors = checks.count { |c| c[:status] == :error }
        warnings = checks.count { |c| c[:status] == :warning }

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

      desc "custom-data:list MODULE TABLE", "List custom data records via the extension API"
      option :project, type: :numeric, required: true, desc: "Project ID"
      option :limit, type: :numeric, default: 50, desc: "Maximum number of records to fetch"
      option :filters, type: :string, desc: "JSON filters (e.g. '{\"status\":\"open\"}')"
      option :api_key, type: :string, desc: "Extension API key (defaults to KIKET_EXTENSION_API_KEY)"
      def custom_data_list(module_key, table)
        params = {
          project_id: options[:project],
          limit: options[:limit]
        }
        params[:filters] = parse_json_option(options[:filters], "--filters") if options[:filters]

        response = client.get(
          "/api/v1/ext/custom_data/#{module_key}/#{table}",
          params: params,
          headers: extension_api_headers
        )

        rows = response.fetch("data", [])
        output_data(rows, headers: rows.first&.keys)
      rescue StandardError => e
        handle_error(e)
      end

      desc "custom-data:get MODULE TABLE ID", "Fetch a single custom data record"
      option :project, type: :numeric, required: true, desc: "Project ID"
      option :api_key, type: :string, desc: "Extension API key"
      def custom_data_get(module_key, table, record_id)
        response = client.get(
          "/api/v1/ext/custom_data/#{module_key}/#{table}/#{record_id}",
          params: { project_id: options[:project] },
          headers: extension_api_headers
        )

        row = response.fetch("data")
        output_data([row], headers: row.keys)
      rescue StandardError => e
        handle_error(e)
      end

      desc "custom-data:create MODULE TABLE", "Create a custom data record"
      option :project, type: :numeric, required: true, desc: "Project ID"
      option :record, type: :string, required: true, desc: "JSON payload for the record"
      option :api_key, type: :string, desc: "Extension API key"
      def custom_data_create(module_key, table)
        record = parse_json_option(options[:record], "--record")
        response = client.post(
          "/api/v1/ext/custom_data/#{module_key}/#{table}",
          params: { project_id: options[:project] },
          body: { record: record },
          headers: extension_api_headers
        )

        row = response.fetch("data")
        output_data([row], headers: row.keys)
      rescue StandardError => e
        handle_error(e)
      end

      desc "custom-data:update MODULE TABLE ID", "Update a custom data record"
      option :project, type: :numeric, required: true, desc: "Project ID"
      option :record, type: :string, required: true, desc: "JSON payload for updates"
      option :api_key, type: :string, desc: "Extension API key"
      def custom_data_update(module_key, table, record_id)
        record = parse_json_option(options[:record], "--record")
        response = client.patch(
          "/api/v1/ext/custom_data/#{module_key}/#{table}/#{record_id}",
          params: { project_id: options[:project] },
          body: { record: record },
          headers: extension_api_headers
        )

        row = response.fetch("data")
        output_data([row], headers: row.keys)
      rescue StandardError => e
        handle_error(e)
      end

      desc "custom-data:delete MODULE TABLE ID", "Delete a custom data record"
      option :project, type: :numeric, required: true, desc: "Project ID"
      option :api_key, type: :string, desc: "Extension API key"
      def custom_data_delete(module_key, table, record_id)
        client.delete(
          "/api/v1/ext/custom_data/#{module_key}/#{table}/#{record_id}",
          params: { project_id: options[:project] },
          headers: extension_api_headers
        )
        success "Deleted record #{record_id}"
      rescue StandardError => e
        handle_error(e)
      end

      desc "secrets:pull EXTENSION_ID", "Download extension-scoped secrets into an env file"
      option :output, type: :string, default: ".env.extension", desc: "Destination env file"
      def extension_secrets_pull(extension_id)
        ensure_authenticated!
        env_path = options[:output]
        secrets = client.get("/api/v1/extensions/#{extension_id}/secrets")
        File.open(env_path, "w") do |file|
          file.puts "# Synced secrets for #{extension_id} at #{Time.now.utc}"
          secrets.each do |meta|
            detail = client.get("/api/v1/extensions/#{extension_id}/secrets/#{meta["key"]}")
            next unless detail["value"]
            file.puts "#{meta["key"]}=#{detail["value"]}"
          end
        end
        success "Secrets written to #{env_path}"
      rescue StandardError => e
        handle_error(e)
      end

      desc "secrets:push EXTENSION_ID", "Push secrets from an env file to the platform"
      option :env_file, type: :string, default: ".env", desc: "Env file containing KEY=VALUE pairs"
      def extension_secrets_push(extension_id)
        ensure_authenticated!
        env_path = options[:env_file]
        values = load_env_file(env_path)
        if values.empty?
          warning "No secrets found in #{env_path}"
          return
        end

        values.each do |key, value|
          store_extension_secret(extension_id, key, value)
        end

        success "Synced #{values.size} secret(s) to #{extension_id}"
      rescue StandardError => e
        handle_error(e)
      end

      private

      def generate_manifest(dir, name, template_type, extension_id: nil)
        manifest_dir = File.join(dir, ".kiket")
        FileUtils.mkdir_p(manifest_dir)
        resolved_id = extension_id.presence || default_extension_id(name)

        manifest = {
          "model_version" => "1.0",
          "extension" => {
            "id" => resolved_id,
            "name" => name,
            "version" => "1.0.0",
            "description" => "Description of #{name}"
          },
          "delivery" => {
            "type" => "http",
            "url" => "https://your-extension.example.com/webhook",
            "timeout" => 5000,
            "retries" => 3
          },
          "hooks" => generate_hooks_for_template(template_type),
          "permissions" => ["read:issues", "write:issues"],
          "configuration" => {
            "fields" => []
          }
        }

        File.write(File.join(manifest_dir, "manifest.yaml"), YAML.dump(manifest))
      end

      def generate_hooks_for_template(template_type)
        case template_type
        when "webhook_guard"
          ["before_transition"]
        when "outbound_integration"
          ["after_transition"]
        when "notification_pack"
          %w[after_transition issue_created issue_updated]
        else
          []
        end
      end

      def generate_python_extension(dir, name, _template_type)
        # Create directory structure
        src_dir = File.join(dir, "src")
        FileUtils.mkdir_p(src_dir)

        # Generate main handler
        File.write(File.join(src_dir, "handler.py"), <<~PYTHON)
          """
          #{name} Extension Handler

          This extension handles workflow events from Kiket.
          """
          from typing import Dict, Any


          def handle_event(event: Dict[str, Any]) -> Dict[str, Any]:
              """
              Main event handler for the extension.

              Args:
                  event: Event payload from Kiket

              Returns:
                  Response dict with status and optional message
              """
              event_type = event.get("event_type")

              if event_type == "before_transition":
                  return handle_before_transition(event)
              elif event_type == "after_transition":
                  return handle_after_transition(event)
              else:
                  return {"status": "allow", "message": "Unknown event type"}


          def handle_before_transition(event: Dict[str, Any]) -> Dict[str, Any]:
              """Handle before_transition events."""
              # Add your logic here
              return {"status": "allow"}


          def handle_after_transition(event: Dict[str, Any]) -> Dict[str, Any]:
              """Handle after_transition events."""
              # Add your logic here
              return {"status": "allow"}
        PYTHON

        # Generate requirements.txt
        File.write(File.join(dir, "requirements.txt"), <<~REQUIREMENTS)
          kiket-sdk>=0.1.0
          requests>=2.31.0
          pyyaml>=6.0
        REQUIREMENTS

        # Generate setup files
        File.write(File.join(dir, "setup.py"), <<~SETUP)
          from setuptools import setup, find_packages

          setup(
              name="#{name.tr(" ", "_").downcase}",
              version="1.0.0",
              packages=find_packages(where="src"),
              package_dir={"": "src"},
              install_requires=[
                  "kiket-sdk>=0.1.0",
              ],
          )
        SETUP
      end

      def generate_typescript_extension(dir, name, _template_type)
        src_dir = File.join(dir, "src")
        FileUtils.mkdir_p(src_dir)

        File.write(File.join(src_dir, "handler.ts"), <<~TYPESCRIPT)
          /**
           * #{name} Extension Handler
           */
          import { KiketEvent, ExtensionResponse } from '@kiket/sdk';

          export async function handleEvent(event: KiketEvent): Promise<ExtensionResponse> {
            const { event_type } = event;

            switch (event_type) {
              case 'before_transition':
                return handleBeforeTransition(event);
              case 'after_transition':
                return handleAfterTransition(event);
              default:
                return { status: 'allow', message: 'Unknown event type' };
            }
          }

          async function handleBeforeTransition(event: KiketEvent): Promise<ExtensionResponse> {
            // Add your logic here
            return { status: 'allow' };
          }

          async function handleAfterTransition(event: KiketEvent): Promise<ExtensionResponse> {
            // Add your logic here
            return { status: 'allow' };
          }
        TYPESCRIPT

        File.write(File.join(dir, "package.json"), <<~JSON)
          {
            "name": "#{name.tr(" ", "-").downcase}",
            "version": "1.0.0",
            "main": "dist/handler.js",
            "scripts": {
              "build": "tsc",
              "test": "jest",
              "lint": "eslint src/**/*.ts"
            },
            "dependencies": {
              "@kiket/sdk": "^0.1.0"
            },
            "devDependencies": {
              "@types/node": "^20.0.0",
              "@typescript-eslint/eslint-plugin": "^6.0.0",
              "@typescript-eslint/parser": "^6.0.0",
              "eslint": "^8.0.0",
              "jest": "^29.0.0",
              "ts-jest": "^29.0.0",
              "typescript": "^5.0.0"
            }
          }
        JSON

        File.write(File.join(dir, "tsconfig.json"), <<~JSON)
          {
            "compilerOptions": {
              "target": "ES2020",
              "module": "commonjs",
              "outDir": "./dist",
              "rootDir": "./src",
              "strict": true,
              "esModuleInterop": true
            },
            "include": ["src/**/*"],
            "exclude": ["node_modules", "dist"]
          }
        JSON
      end

      def generate_ruby_extension(dir, name, _template_type)
        lib_dir = File.join(dir, "lib")
        FileUtils.mkdir_p(lib_dir)

        module_name = name.gsub(/\s+/, "")

        File.write(File.join(lib_dir, "handler.rb"), <<~RUBY)
          # frozen_string_literal: true

          require "kiket"

          module #{module_name}
            class Handler
              def self.handle_event(event)
                event_type = event["event_type"]

                case event_type
                when "before_transition"
                  handle_before_transition(event)
                when "after_transition"
                  handle_after_transition(event)
                else
                  { status: "allow", message: "Unknown event type" }
                end
              end

              def self.handle_before_transition(event)
                # Add your logic here
                { status: "allow" }
              end

              def self.handle_after_transition(event)
                # Add your logic here
                { status: "allow" }
              end
            end
          end
        RUBY

        File.write(File.join(dir, "Gemfile"), <<~GEMFILE)
          source "https://rubygems.org"

          gem "kiket-sdk", "~> 0.1.0"

          group :development, :test do
            gem "rspec"
            gem "rubocop"
          end
        GEMFILE
      end

      def generate_readme(dir, name, sdk)
        File.write(File.join(dir, "README.md"), <<~README)
          # #{name}

          A Kiket extension built with #{sdk.capitalize}.

          ## Description

          TODO: Add extension description

          ## Installation

          TODO: Add installation instructions

          ## Configuration

          TODO: Document configuration options

          ## Development

          ### Testing

          ```bash
          kiket extensions test
          ```

          ### Linting

          ```bash
          kiket extensions lint --fix
          ```

          ### Publishing

          ```bash
          kiket extensions publish
          ```

          ## License

          MIT
        README
      end

      def generate_gitignore(dir)
    File.write(File.join(dir, ".gitignore"), <<~GITIGNORE)
          # Dependencies
          node_modules/
          __pycache__/
          *.pyc
          .venv/
          venv/
          vendor/

          # Build outputs
          dist/
          build/
          *.egg-info/

          # IDE
          .vscode/
          .idea/
          *.swp
          *.swo

          # OS
          .DS_Store
          Thumbs.db

          # Test coverage
          coverage/
          .coverage
          htmlcov/

          # Logs
          *.log
        GITIGNORE
      end

      def generate_env_example(dir)
    File.write(File.join(dir, ".env.example"), <<~ENVFILE)
      # Example secrets - copy to .env and update values
      # Use `kiket extensions secrets push <extension_id> --env-file .env`
      SAMPLE_API_TOKEN=replace_me
      SAMPLE_WEBHOOK_SECRET=replace_me
        ENVFILE
      end

      def generate_replay_samples(dir, template_type)
    replay_dir = File.join(dir, "replay")
    FileUtils.mkdir_p(replay_dir)
    REPLAY_TEMPLATES.each do |name, payload|
      File.write(
        File.join(replay_dir, "#{name}.json"),
        JSON.pretty_generate(payload.merge("template_hint" => template_type))
      )
    end
      end

      def generate_tests(dir, sdk, _template_type, name)
        case sdk
        when "python"
          test_dir = File.join(dir, "tests")
          FileUtils.mkdir_p(test_dir)

          File.write(File.join(test_dir, "test_handler.py"), <<~PYTHON)
            import pytest
            from src.handler import handle_event


            def test_handle_before_transition():
                event = {
                    "event_type": "before_transition",
                    "organization_id": "org-123",
                    "project_id": "proj-456"
                }
                response = handle_event(event)
                assert response["status"] in ["allow", "deny", "pending_approval"]


            def test_handle_after_transition():
                event = {
                    "event_type": "after_transition",
                    "organization_id": "org-123",
                    "project_id": "proj-456"
                }
                response = handle_event(event)
                assert response["status"] == "allow"
          PYTHON

      File.write(File.join(dir, "pytest.ini"), <<~INI)
        [pytest]
        testpaths = tests
        python_files = test_*.py
        python_classes = Test*
        python_functions = test_*
          INI
        when "node"
          test_dir = File.join(dir, "tests")
          FileUtils.mkdir_p(test_dir)

      File.write(File.join(test_dir, "handler.test.ts"), <<~TS)
        import { handleEvent } from '../src/handler';

        test('before transition allows by default', async () => {
          const response = await handleEvent({ event_type: 'before_transition' } as any);
          expect(response.status).toBeDefined();
        });
      TS

      File.write(File.join(dir, "jest.config.js"), <<~JS)
        module.exports = {
          preset: 'ts-jest',
          testEnvironment: 'node',
          roots: ['<rootDir>/tests']
        };
          JS
        when "ruby"
          spec_dir = File.join(dir, "spec")
          FileUtils.mkdir_p(spec_dir)

      module_name = name.gsub(/\s+/, "")

      File.write(File.join(spec_dir, "handler_spec.rb"), <<~RUBY)
        # frozen_string_literal: true

        require "rspec"
        require_relative "../lib/handler"

        RSpec.describe #{module_name}::Handler do
          it "allows unknown events" do
            expect(described_class.handle_event("event_type" => "unknown")[:status]).to eq("allow")
          end
        end
          RUBY
        end
      end

      def generate_github_actions(dir, sdk)
        workflows_dir = File.join(dir, ".github", "workflows")
        FileUtils.mkdir_p(workflows_dir)

        case sdk
        when "python"
          File.write(File.join(workflows_dir, "test.yml"), <<~YAML)
            name: Test

            on: [push, pull_request]

            jobs:
              test:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - uses: actions/setup-python@v4
                    with:
                      python-version: '3.11'
                  - run: pip install -r requirements.txt
                  - run: pytest
                  - run: ruff check .
          YAML
        when "node"
          File.write(File.join(workflows_dir, "test.yml"), <<~YAML)
            name: Test

            on: [push, pull_request]

            jobs:
              test:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - uses: actions/setup-node@v4
                    with:
                      node-version: '20'
                  - run: npm install
                  - run: npm run lint
                  - run: npm test -- --runInBand
          YAML
        when "ruby"
          File.write(File.join(workflows_dir, "test.yml"), <<~YAML)
            name: Test

            on: [push, pull_request]

            jobs:
              test:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - uses: ruby/setup-ruby@v1
                    with:
                      ruby-version: '3.2'
                      bundler-cache: true
                  - run: bundle exec rspec
          YAML
        end
      end

      def create_tarball(root, archive_path)
        Dir.chdir(root) do
          entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject do |entry|
            entry == "." ||
              entry == ".." ||
              entry.start_with?("dist/") ||
              entry.start_with?(".git/")
          end

          File.open(archive_path, "wb") do |file|
            Zlib::GzipWriter.wrap(file) do |gzip|
              Gem::Package::TarWriter.new(gzip) do |tar|
                entries.each do |entry|
                  stat = File.stat(entry)
                  if stat.directory?
                    tar.mkdir(entry, stat.mode)
                  else
                    tar.add_file_simple(entry, stat.mode, stat.size) do |io|
                      io.write(File.binread(entry))
                    end
                  end
                end
              end
            end
          end
        end
      end

      no_commands do
        def extension_api_headers
          api_key = options[:api_key] || ENV.fetch("KIKET_EXTENSION_API_KEY", nil)
          if api_key.nil? || api_key.empty?
            error "Missing extension API key. Provide --api-key or set KIKET_EXTENSION_API_KEY."
            exit 1
          end

          { "X-Kiket-API-Key" => api_key }
        end

        def parse_json_option(value, flag)
          return {} if value.nil?

          require "multi_json"
          MultiJson.load(value)
        rescue MultiJson::ParseError => e
          error "#{flag} must be valid JSON: #{e.message}"
          exit 1
        end

        def validate_custom_data_assets(path, manifest)
          errors = []
          warnings = []
          modules_root = File.join(path, ".kiket", "modules")
          return { errors: errors, warnings: warnings } unless Dir.exist?(modules_root)

          module_files = Dir.glob(File.join(modules_root, "*", "schema.{yml,yaml}"))
          local_modules = {}

          module_files.each do |file|
            data = YAML.safe_load_file(file)
            module_id = data.dig("module", "id")
            if module_id.nil?
              errors << "#{relative_to_repo(file)} missing module.id"
              next
            end

            tables = Array(data.dig("module", "tables"))
            errors << "#{relative_to_repo(file)} must define at least one table" if tables.empty?
            local_modules[module_id] = file
          rescue Psych::SyntaxError => e
            errors << "Invalid YAML in #{relative_to_repo(file)}: #{e.message}"
          end

          permissions = Array(manifest.dig("extension", "custom_data", "permissions"))
          permissions.each do |entry|
            module_id = entry["module"] || entry[:module]
            next unless module_id

            ops = Array(entry["operations"] || entry[:operations]).map(&:to_s)
            invalid = ops.reject { |op| %w[read write admin].include?(op) }
            if invalid.any?
              errors << "custom_data permission for #{module_id} has invalid operations #{invalid.join(", ")}"
            end
          end

          missing_permissions = local_modules.keys.reject do |module_id|
            permissions.any? { |entry| (entry["module"] || entry[:module]) == module_id }
          end

          missing_permissions.each do |module_id|
            warnings << "Module #{module_id} is defined but not declared in extension.custom_data.permissions"
          end

          { errors: errors, warnings: warnings }
        end

        def relative_to_repo(path)
          Pathname.new(path).relative_path_from(Pathname.new(Dir.pwd)).to_s
        rescue ArgumentError
          path
        end

        def default_extension_id(name)
          slug = name.to_s.downcase.gsub(/[^a-z0-9]+/, ".").gsub(/\.{2,}/, ".").gsub(/\A\.|\.\z/, "")
          slug = "example.#{SecureRandom.hex(2)}" if slug.empty?
          parts = slug.split(".")
          parts.unshift("com") if parts.length < 2
          parts.join(".")
        end

        def build_replay_payload(opts)
          require "multi_json"
        payload = if present?(opts[:payload])
                      MultiJson.load(File.read(opts[:payload]))
                    elsif present?(opts[:template])
                      template = REPLAY_TEMPLATES[opts[:template]]
                      raise ArgumentError, "Unknown template #{opts[:template]}" unless template
                      MultiJson.load(MultiJson.dump(template))
                    else
                      input = STDIN.read
                      raise ArgumentError, "No payload provided (pass --payload or pipe data)" if input.strip.empty?
                      MultiJson.load(input)
                    end

          secrets = {}
          if present?(opts[:env_file])
            secrets.merge!(load_env_file(opts[:env_file]))
          end

          prefix = opts[:secret_prefix].to_s
          if present?(prefix)
            ENV.each do |key, value|
              next unless key.start_with?(prefix)
              secrets[key.delete_prefix(prefix)] = value
            end
          end

          if secrets.any?
            payload["secrets"] ||= {}
            payload["secrets"].merge!(secrets)
          end

          payload
        end

        def perform_replay_request(url, method, body, headers)
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.read_timeout = 10
          klass = case method.to_s.upcase
                  when "POST" then Net::HTTP::Post
                  when "PUT" then Net::HTTP::Put
                  else Net::HTTP::Post
                  end
          request = klass.new(uri.request_uri)
          headers.each { |k, v| request[k] = v }
          request.body = body
          http.request(request)
        end

        def load_env_file(path)
          return {} if blank?(path)
          unless File.exist?(path)
            warning "Env file #{path} not found"
            return {}
          end

          File.readlines(path).each_with_object({}) do |line, acc|
            line = line.strip
            next if line.empty? || line.start_with?("#")
            key, value = line.split("=", 2)
            next unless key && value
            acc[key.strip] = value.strip
          end
        rescue StandardError => e
          warning "Failed to read #{path}: #{e.message}"
          {}
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
      end
    end
  end
end
