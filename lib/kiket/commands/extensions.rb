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

      VALID_STEP_TYPES = %w[secrets configure test info].freeze
      VALID_OBTAIN_TYPES = %w[oauth2 oauth2_client_credentials api_key token input basic auto_generate].freeze
      VALID_SDK_VALUES = %w[ruby python node java dotnet go].freeze

      map(
        "custom-data:list" => :custom_data_list,
        "custom-data:get" => :custom_data_get,
        "custom-data:create" => :custom_data_create,
        "custom-data:update" => :custom_data_update,
        "custom-data:delete" => :custom_data_delete,
        "secrets:pull" => :extension_secrets_pull,
        "secrets:push" => :extension_secrets_push,
        "wizard:preview" => :wizard_preview
      )
      desc "scaffold NAME", "Generate a new extension project"
      option :sdk, type: :string, default: "python", desc: "SDK language (python, node, ruby, java, dotnet, go)"
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

        unless VALID_SDK_VALUES.include?(sdk)
          error "Unsupported SDK '#{sdk}'. Supported values: #{VALID_SDK_VALUES.join(", ")}."
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
        when "java"
          generate_java_extension(dir, name, template_type)
        when "dotnet"
          generate_dotnet_extension(dir, name, template_type)
        when "go"
          generate_go_extension(dir, name, template_type)
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
        success "Manifest created at #{File.join(dir, ".kiket/manifest.yaml")}"
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

        # Validate model_version
        warnings << "Missing model_version (recommended: \"1.0\")" unless manifest["model_version"]

        # Require nested extension block (canonical format)
        unless manifest["extension"].is_a?(Hash)
          errors << "Missing 'extension:' block - use nested format with model_version: \"1.0\""
        end

        # Required fields - only accept nested extension.id format
        extension_id = manifest.dig("extension", "id")
        extension_name = manifest.dig("extension", "name")
        errors << "Missing extension.id" unless extension_id
        errors << "Missing extension.name" unless extension_name

        # Validate extension ID format
        if extension_id && !extension_id.match?(/^[a-z][a-z0-9.-]+$/)
          warnings << "extension.id should use lowercase with dots (e.g., dev.kiket.ext.myextension)"
        end

        # Validate delivery configuration - only accept string format with callback block
        delivery = manifest.dig("extension", "delivery")
        errors << "Missing extension.delivery" unless delivery

        if delivery
          unless delivery.is_a?(String)
            errors << "extension.delivery must be a string ('http' or 'internal'), not a hash"
          end

          unless %w[http internal].include?(delivery)
            errors << "extension.delivery must be 'http' or 'internal', got '#{delivery}'"
          end

          if delivery == "http"
            callback = manifest.dig("extension", "callback")
            errors << "extension.callback block required for HTTP delivery" unless callback.is_a?(Hash)

            callback_url = callback&.dig("url")
            errors << "Missing extension.callback.url" unless callback_url

            timeout = callback&.dig("timeout")
            if timeout && (timeout < 100 || timeout > 60_000)
              errors << "extension.callback.timeout must be between 100 and 60000ms"
            end
          end
        end

        # Check for test files
        test_dirs = Dir.glob("#{path}/{test,spec,tests}").select { |f| File.directory?(f) }
        warnings << "No test directory found" if test_dirs.empty?

        # Check for README
        warnings << "No README.md found" unless File.exist?(File.join(path, "README.md"))

        # Validate sdk field
        sdk_value = manifest.dig("extension", "sdk")
        if sdk_value
          unless VALID_SDK_VALUES.include?(sdk_value)
            errors << "Invalid extension.sdk value '#{sdk_value}'. Valid: #{VALID_SDK_VALUES.join(", ")}"
          end
        else
          warnings << "Missing extension.sdk field (recommended for deployment)"
        end

        custom_data_results = validate_custom_data_assets(path, manifest)
        errors.concat(custom_data_results[:errors])
        warnings.concat(custom_data_results[:warnings])

        # Validate wizard setup steps
        wizard_results = validate_wizard_setup(manifest)
        errors.concat(wizard_results[:errors])
        warnings.concat(wizard_results[:warnings])

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
          args = ["ruff", "check", "."]
          args << "--fix" if options[:fix]
          system(*args, chdir: path)
        elsif File.exist?(File.join(path, "package.json"))
          info "Running TypeScript linting..."
          args = %w[npm run lint]
          args.push("--", "--fix") if options[:fix]
          system(*args, chdir: path)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "test [PATH]", "Run extension tests"
      option :watch, type: :boolean, desc: "Watch for changes"
      def test(path = ".")
        runner = detect_test_runner(path)
        unless runner
          error "No supported test configuration found in #{path}."
          info "Add tests via `kiket extensions scaffold` or define a package.json/pyproject/Gemfile test target."
          exit 1
        end

        info "Running #{runner[:label]}..."
        command = runner[:command]

        if options[:watch]
          if runner[:watch_command]
            command = runner[:watch_command]
          elsif runner[:watch_flag]
            command = "#{command} #{runner[:watch_flag]}"
          else
            warning "Watch mode is not available for #{runner[:label]} – running once instead."
          end
        end

        success = run_shell(command)
        exit 1 unless success
      rescue StandardError => e
        handle_error(e)
      end

      desc "replay", "Replay a recorded payload against a local extension endpoint"
      option :payload, type: :string, desc: "Path to JSON payload (defaults to STDIN)"
      option :template, type: :string, desc: "Built-in template (#{REPLAY_TEMPLATES.keys.join(", ")})"
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
        stdout, _, status = Open3.capture3("git", "-C", path, "remote", "get-url", "origin")

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
        stdout, = Open3.capture3("git", "-C", path, "status", "--porcelain")

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
        remote_url, = Open3.capture2("git", "-C", path, "remote", "get-url", "origin")
        remote_url = remote_url.strip

        current_branch, = Open3.capture2("git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD")
        current_branch = current_branch.strip

        git_ref = options[:ref] || current_branch

        commit_sha, = Open3.capture2("git", "-C", path, "rev-parse", git_ref)
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

      desc "wizard:preview [PATH]", "Preview wizard setup steps in the terminal"
      option :step, type: :numeric, desc: "Show specific step (1-indexed)"
      option :json, type: :boolean, desc: "Output as JSON"
      def wizard_preview(path = ".")
        manifest_path = File.join(path, ".kiket", "manifest.yaml")

        unless File.exist?(manifest_path)
          error "No manifest.yaml found at #{manifest_path}"
          exit 1
        end

        require "yaml"
        manifest = YAML.load_file(manifest_path)
        setup_steps = manifest.dig("extension", "setup") || manifest["setup"]

        if setup_steps.nil? || setup_steps.empty?
          warning "No setup wizard steps found in manifest"
          info "Add 'extension.setup' to your manifest to define wizard steps"
          exit 0
        end

        if options[:json]
          require "json"
          puts JSON.pretty_generate(setup_steps)
          return
        end

        puts pastel.bold("\nWizard Setup Steps\n")
        puts "Extension: #{manifest.dig("extension", "name") || manifest["name"]}"
        puts "Total steps: #{setup_steps.length}\n\n"

        setup_steps.each_with_index do |step, index|
          next if options[:step] && options[:step] != (index + 1)

          step_type = step.keys.first
          step_config = step[step_type]

          puts pastel.cyan("Step #{index + 1}: #{step_type.upcase}")
          puts "  Title: #{step_config["title"]}" if step_config["title"]
          puts "  Description: #{step_config["description"]}" if step_config["description"]

          case step_type
          when "secrets"
            fields = step_config["fields"] || []
            puts "  Fields (#{fields.length}):"
            fields.each do |field|
              obtain_type = field.dig("obtain", "type") || "input"
              secret = field.dig("obtain", "secret") ? " 🔒" : ""
              puts "    - #{field["key"]} (#{obtain_type})#{secret}"
              puts "      Label: #{field["label"]}" if field["label"]
            end

          when "configure"
            fields = step_config["fields"] || []
            puts "  Fields (#{fields.length}):"
            fields.each do |field|
              required = field["required"] ? " *" : ""
              show_when = field["showWhen"] ? " [conditional]" : ""
              puts "    - #{field["key"]} (#{field["type"] || "text"})#{required}#{show_when}"
              puts "      Label: #{field["label"]}" if field["label"]
            end

          when "test"
            puts "  Action: #{step_config["action"]}" if step_config["action"]
            puts "  Success message: #{step_config["successMessage"]}" if step_config["successMessage"]

          when "info"
            content = step_config["content"] || ""
            preview = content.split("\n").first(3).join("\n")
            puts "  Content preview:"
            puts "    #{preview.gsub("\n", "\n    ")}..."
            links = step_config["links"] || []
            if links.any?
              puts "  Links:"
              links.each do |link|
                puts "    - #{link["label"]}: #{link["url"]}"
              end
            end
          end

          puts ""
        end

        # Validate and show warnings
        results = validate_wizard_setup(manifest)
        if results[:warnings].any?
          warning "Warnings:"
          results[:warnings].each { |w| puts "  ⚠ #{w}" }
        end
        if results[:errors].any?
          error "Errors:"
          results[:errors].each { |e| puts "  ✗ #{e}" }
          exit 1
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "custom-data:list MODULE TABLE", "List custom data records via the workspace API"
      option :project, type: :numeric, desc: "Project ID"
      option :project_key, type: :string, desc: "Project key"
      option :limit, type: :numeric, default: 50, desc: "Maximum number of records to fetch"
      option :filters, type: :string, desc: "JSON filters (e.g. '{\"status\":\"open\"}')"
      def custom_data_list(module_key, table)
        ensure_authenticated!
        params = custom_data_scope_params
        params[:limit] = options[:limit]
        params[:filters] = parse_json_option(options[:filters], "--filters") if options[:filters]

        response = client.get(
          "/api/v1/custom_data/#{module_key}/#{table}",
          params: params
        )

        rows = response.fetch("data", [])
        output_data(rows, headers: rows.first&.keys)
      rescue StandardError => e
        handle_error(e)
      end

      desc "custom-data:get MODULE TABLE ID", "Fetch a single custom data record"
      option :project, type: :numeric, desc: "Project ID"
      option :project_key, type: :string, desc: "Project key"
      def custom_data_get(module_key, table, record_id)
        ensure_authenticated!
        response = client.get(
          "/api/v1/custom_data/#{module_key}/#{table}/#{record_id}",
          params: custom_data_scope_params
        )

        row = response.fetch("data")
        output_data([row], headers: row.keys)
      rescue StandardError => e
        handle_error(e)
      end

      desc "custom-data:create MODULE TABLE", "Create a custom data record"
      option :project, type: :numeric, desc: "Project ID"
      option :project_key, type: :string, desc: "Project key"
      option :record, type: :string, required: true, desc: "JSON payload for the record"
      def custom_data_create(module_key, table)
        ensure_authenticated!
        record = parse_json_option(options[:record], "--record")
        response = client.post(
          "/api/v1/custom_data/#{module_key}/#{table}",
          params: custom_data_scope_params,
          body: { record: record }
        )

        row = response.fetch("data")
        output_data([row], headers: row.keys)
      rescue StandardError => e
        handle_error(e)
      end

      desc "custom-data:update MODULE TABLE ID", "Update a custom data record"
      option :project, type: :numeric, desc: "Project ID"
      option :project_key, type: :string, desc: "Project key"
      option :record, type: :string, required: true, desc: "JSON payload for updates"
      def custom_data_update(module_key, table, record_id)
        ensure_authenticated!
        record = parse_json_option(options[:record], "--record")
        response = client.patch(
          "/api/v1/custom_data/#{module_key}/#{table}/#{record_id}",
          params: custom_data_scope_params,
          body: { record: record }
        )

        row = response.fetch("data")
        output_data([row], headers: row.keys)
      rescue StandardError => e
        handle_error(e)
      end

      desc "custom-data:delete MODULE TABLE ID", "Delete a custom data record"
      option :project, type: :numeric, desc: "Project ID"
      option :project_key, type: :string, desc: "Project key"
      def custom_data_delete(module_key, table, record_id)
        ensure_authenticated!
        client.delete(
          "/api/v1/custom_data/#{module_key}/#{table}/#{record_id}",
          params: custom_data_scope_params
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

      no_commands do
        def detect_test_runner(path)
          detect_python_test_runner(path) ||
            detect_node_test_runner(path) ||
            detect_ruby_test_runner(path)
        end

        def detect_python_test_runner(path)
          poetry = poetry_project?(path)
          pipenv = pipenv_project?(path)
          return nil unless poetry || pipenv || File.exist?(File.join(path,
                                                                      "requirements.txt")) || File.exist?(File.join(
                                                                                                            path, "pyproject.toml"
                                                                                                          ))

          command = [
            "cd #{path} &&",
            if poetry
              "poetry run pytest"
            elsif pipenv
              "pipenv run pytest"
            else
              "python -m pytest"
            end
          ].join(" ")

          {
            label: "pytest",
            command: command,
            watch_command: python_watch_command(path, poetry: poetry, pipenv: pipenv)
          }
        end

        def detect_node_test_runner(path)
          package_json_path = File.join(path, "package.json")
          return nil unless File.exist?(package_json_path)

          pkg = JSON.parse(File.read(package_json_path))
          scripts = pkg["scripts"] || {}
          unless scripts.key?("test")
            warning "package.json found but no test script defined. Add `\"test\": \"jest\"` (or similar) to run CLI tests."
            return nil
          end

          manager = detect_node_package_manager(path)
          base_command = [
            "cd #{path} &&",
            case manager
            when :pnpm then "pnpm test"
            when :yarn then "yarn test"
            else "npm test"
            end
          ].join(" ")

          watch_command =
            case manager
            when :pnpm
              "#{base_command} --watch"
            when :yarn
              "#{base_command} --watch"
            else
              "#{base_command} -- --watch"
            end

          {
            label: "Node test/#{manager}",
            command: base_command,
            watch_command: watch_command
          }
        rescue JSON::ParserError => e
          warning "Unable to parse package.json: #{e.message}"
          nil
        end

        def detect_ruby_test_runner(path)
          gemfile = File.join(path, "Gemfile")
          return nil unless File.exist?(gemfile)

          {
            label: "RSpec",
            command: "cd #{path} && bundle exec rspec"
          }
        end

        def python_watch_command(path, poetry:, pipenv:)
          return nil unless command_available?("ptw")

          base =
            if poetry
              "poetry run ptw"
            elsif pipenv
              "pipenv run ptw"
            else
              "ptw"
            end

          "cd #{path} && #{base}"
        end

        def detect_node_package_manager(path)
          return :pnpm if File.exist?(File.join(path, "pnpm-lock.yaml"))
          return :yarn if File.exist?(File.join(path, "yarn.lock"))
          return :npm if File.exist?(File.join(path, "package-lock.json"))

          package_manager_field = package_manager_from_package_json(path)
          return :pnpm if package_manager_field&.include?("pnpm")
          return :yarn if package_manager_field&.include?("yarn")

          :npm
        end

        def package_manager_from_package_json(path)
          package_json_path = File.join(path, "package.json")
          return nil unless File.exist?(package_json_path)

          pkg = JSON.parse(File.read(package_json_path))
          pkg["packageManager"]
        rescue JSON::ParserError
          nil
        end

        def poetry_project?(path)
          File.exist?(File.join(path,
                                "poetry.lock")) || file_contains?(File.join(path, "pyproject.toml"), "[tool.poetry]")
        end

        def pipenv_project?(path)
          File.exist?(File.join(path, "Pipfile")) || File.exist?(File.join(path, "Pipfile.lock"))
        end

        def file_contains?(path, needle)
          return false unless File.exist?(path)

          File.read(path).include?(needle)
        rescue Errno::ENOENT
          false
        end

        def command_available?(command)
          system("command", "-v", command, out: File::NULL, err: File::NULL)
        end

        def run_shell(command)
          system(command)
        end
      end

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
            "description" => "Description of #{name}",
            "setup" => generate_wizard_steps_for_template(template_type, name)
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

      def generate_wizard_steps_for_template(template_type, name)
        base_steps = [
          {
            "secrets" => {
              "title" => "Connect to Service",
              "description" => "Enter your API credentials to get started",
              "required" => true,
              "fields" => [
                {
                  "key" => "API_KEY",
                  "label" => "API Key",
                  "obtain" => {
                    "type" => "api_key",
                    "secret" => true,
                    "help_url" => "https://example.com/docs/api-keys"
                  }
                }
              ]
            }
          }
        ]

        case template_type
        when "webhook_guard"
          base_steps + [
            {
              "configure" => {
                "title" => "Guard Settings",
                "description" => "Configure how transitions are validated",
                "fields" => [
                  {
                    "key" => "validation_mode",
                    "type" => "select",
                    "label" => "Validation Mode",
                    "options" => [
                      { "value" => "strict", "label" => "Strict - Block on any failure" },
                      { "value" => "lenient", "label" => "Lenient - Allow with warnings" }
                    ],
                    "default" => "strict"
                  },
                  {
                    "key" => "timeout_seconds",
                    "type" => "number",
                    "label" => "Timeout (seconds)",
                    "default" => 5
                  }
                ]
              }
            },
            {
              "test" => {
                "title" => "Test Connection",
                "description" => "Verify your configuration is working",
                "action" => "#{name.downcase.gsub(/\s+/, ".")}.testConnection",
                "required" => false
              }
            }
          ]

        when "outbound_integration"
          base_steps + [
            {
              "configure" => {
                "title" => "Integration Settings",
                "description" => "Configure how data is sent to the external service",
                "fields" => [
                  {
                    "key" => "sync_mode",
                    "type" => "select",
                    "label" => "Sync Mode",
                    "options" => [
                      { "value" => "realtime", "label" => "Real-time" },
                      { "value" => "batched", "label" => "Batched (every 5 minutes)" }
                    ],
                    "default" => "realtime"
                  }
                ]
              }
            },
            {
              "test" => {
                "title" => "Test Integration",
                "description" => "Send a test event to verify connectivity",
                "action" => "#{name.downcase.gsub(/\s+/, ".")}.testConnection"
              }
            },
            {
              "info" => {
                "title" => "Setup Complete",
                "content" => "## You're all set!\n\nYour #{name} integration is now configured.\n\n- Events will be sent automatically\n- Check the extension logs for delivery status"
              }
            }
          ]

        when "notification_pack"
          [
            {
              "secrets" => {
                "title" => "Connect Notification Service",
                "description" => "Enter your notification service credentials",
                "fields" => [
                  {
                    "key" => "NOTIFICATION_API_KEY",
                    "label" => "API Key",
                    "obtain" => { "type" => "api_key", "secret" => true }
                  }
                ]
              }
            },
            {
              "configure" => {
                "title" => "Notification Settings",
                "description" => "Configure where and how notifications are sent",
                "fields" => [
                  {
                    "key" => "default_channel",
                    "type" => "text",
                    "label" => "Default Channel",
                    "placeholder" => "#general"
                  },
                  {
                    "key" => "notify_on_create",
                    "type" => "boolean",
                    "label" => "Notify on Issue Created",
                    "default" => true
                  },
                  {
                    "key" => "notify_on_transition",
                    "type" => "boolean",
                    "label" => "Notify on Status Change",
                    "default" => true
                  }
                ]
              }
            },
            {
              "test" => {
                "title" => "Test Notifications",
                "description" => "Send a test notification",
                "action" => "#{name.downcase.gsub(/\s+/, ".")}.sendTest",
                "successMessage" => "Test notification sent successfully!"
              }
            },
            {
              "info" => {
                "title" => "Ready to Go",
                "content" => "## Notifications Configured!\n\nYour #{name} notifications are ready.\n\n### What happens next:\n- Issue created → Notification sent\n- Status changes → Notification sent",
                "links" => [
                  { "label" => "Documentation", "url" => "https://docs.kiket.dev" }
                ]
              }
            }
          ]

        else
          # Custom template - minimal steps
          base_steps + [
            {
              "info" => {
                "title" => "Setup Complete",
                "content" => "## #{name} is ready!\n\nYour extension has been configured. Customize this wizard in your manifest.yaml."
              }
            }
          ]
        end
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

      def generate_java_extension(dir, name, _template_type)
        package_name = name.downcase.gsub(/[^a-z0-9]+/, "")
        class_name = name.gsub(/[^a-zA-Z0-9]+/, "")

        src_dir = File.join(dir, "src", "main", "java", "dev", "kiket", "extensions", package_name)
        FileUtils.mkdir_p(src_dir)

        File.write(File.join(src_dir, "Handler.java"), <<~JAVA)
          package dev.kiket.extensions.#{package_name};

          import dev.kiket.sdk.Extension;
          import dev.kiket.sdk.Context;
          import dev.kiket.sdk.Response;

          import java.util.Map;

          /**
           * #{name} Extension Handler
           */
          public class Handler {

              public static void main(String[] args) {
                  Extension.builder()
                      .onBeforeTransition(Handler::handleBeforeTransition)
                      .onAfterTransition(Handler::handleAfterTransition)
                      .run();
              }

              public static Response handleBeforeTransition(Map<String, Object> payload, Context ctx) {
                  // Access secrets via ctx.secret("API_KEY")
                  // Add your logic here
                  return Response.allow();
              }

              public static Response handleAfterTransition(Map<String, Object> payload, Context ctx) {
                  // Add your logic here
                  return Response.allow();
              }
          }
        JAVA

        File.write(File.join(dir, "pom.xml"), <<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <project xmlns="http://maven.apache.org/POM/4.0.0"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                   xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
              <modelVersion>4.0.0</modelVersion>

              <groupId>dev.kiket.extensions</groupId>
              <artifactId>#{name.downcase.gsub(/[^a-z0-9]+/, "-")}</artifactId>
              <version>1.0.0</version>
              <packaging>jar</packaging>

              <properties>
                  <maven.compiler.source>21</maven.compiler.source>
                  <maven.compiler.target>21</maven.compiler.target>
                  <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
              </properties>

              <dependencies>
                  <dependency>
                      <groupId>dev.kiket</groupId>
                      <artifactId>kiket-sdk</artifactId>
                      <version>0.1.0</version>
                  </dependency>
                  <dependency>
                      <groupId>org.junit.jupiter</groupId>
                      <artifactId>junit-jupiter</artifactId>
                      <version>5.10.0</version>
                      <scope>test</scope>
                  </dependency>
              </dependencies>

              <build>
                  <plugins>
                      <plugin>
                          <groupId>org.apache.maven.plugins</groupId>
                          <artifactId>maven-jar-plugin</artifactId>
                          <version>3.3.0</version>
                          <configuration>
                              <archive>
                                  <manifest>
                                      <mainClass>dev.kiket.extensions.#{package_name}.Handler</mainClass>
                                  </manifest>
                              </archive>
                          </configuration>
                      </plugin>
                  </plugins>
              </build>
          </project>
        XML
      end

      def generate_dotnet_extension(dir, name, _template_type)
        namespace = name.gsub(/[^a-zA-Z0-9]+/, "")
        project_name = name.gsub(/[^a-zA-Z0-9]+/, "-")

        FileUtils.mkdir_p(dir)

        File.write(File.join(dir, "Handler.cs"), <<~CSHARP)
          using Kiket.Sdk;
          using System.Collections.Generic;

          namespace #{namespace};

          /// <summary>
          /// #{name} Extension Handler
          /// </summary>
          public class Handler
          {
              public static void Main(string[] args)
              {
                  Extension.Builder()
                      .OnBeforeTransition(HandleBeforeTransition)
                      .OnAfterTransition(HandleAfterTransition)
                      .Run();
              }

              public static Response HandleBeforeTransition(Dictionary<string, object> payload, Context ctx)
              {
                  // Access secrets via ctx.Secret("API_KEY")
                  // Add your logic here
                  return Response.Allow();
              }

              public static Response HandleAfterTransition(Dictionary<string, object> payload, Context ctx)
              {
                  // Add your logic here
                  return Response.Allow();
              }
          }
        CSHARP

        File.write(File.join(dir, "Extension.csproj"), <<~XML)
          <Project Sdk="Microsoft.NET.Sdk">

            <PropertyGroup>
              <OutputType>Exe</OutputType>
              <TargetFramework>net8.0</TargetFramework>
              <RootNamespace>#{namespace}</RootNamespace>
              <ImplicitUsings>enable</ImplicitUsings>
              <Nullable>enable</Nullable>
            </PropertyGroup>

            <ItemGroup>
              <PackageReference Include="Kiket.Sdk" Version="0.1.0" />
            </ItemGroup>

          </Project>
        XML
      end

      def generate_go_extension(dir, name, _template_type)
        package_name = name.downcase.gsub(/[^a-z0-9]+/, "")

        FileUtils.mkdir_p(dir)

        File.write(File.join(dir, "main.go"), <<~GO)
          package main

          import (
              "github.com/kiket-dev/sdk-go/kiket"
          )

          // #{name} Extension Handler
          func main() {
              kiket.NewExtension().
                  OnBeforeTransition(handleBeforeTransition).
                  OnAfterTransition(handleAfterTransition).
                  Run()
          }

          func handleBeforeTransition(payload map[string]interface{}, ctx *kiket.Context) *kiket.Response {
              // Access secrets via ctx.Secret("API_KEY")
              // Add your logic here
              return kiket.Allow()
          }

          func handleAfterTransition(payload map[string]interface{}, ctx *kiket.Context) *kiket.Response {
              // Add your logic here
              return kiket.Allow()
          }
        GO

        File.write(File.join(dir, "go.mod"), <<~GOMOD)
          module #{package_name}

          go 1.23

          require github.com/kiket-dev/sdk-go v0.1.0
        GOMOD
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

        when "java"
          package_name = name.downcase.gsub(/[^a-z0-9]+/, "")
          test_dir = File.join(dir, "src", "test", "java", "dev", "kiket", "extensions", package_name)
          FileUtils.mkdir_p(test_dir)

          File.write(File.join(test_dir, "HandlerTest.java"), <<~JAVA)
            package dev.kiket.extensions.#{package_name};

            import org.junit.jupiter.api.Test;
            import static org.junit.jupiter.api.Assertions.*;

            import dev.kiket.sdk.Response;
            import java.util.HashMap;
            import java.util.Map;

            class HandlerTest {

                @Test
                void testHandleBeforeTransition() {
                    Map<String, Object> payload = new HashMap<>();
                    payload.put("event_type", "before_transition");

                    // Test that handler returns a valid response
                    // Note: Full integration test requires mock context
                    assertNotNull(payload.get("event_type"));
                }

                @Test
                void testHandleAfterTransition() {
                    Map<String, Object> payload = new HashMap<>();
                    payload.put("event_type", "after_transition");

                    assertNotNull(payload.get("event_type"));
                }
            }
          JAVA

        when "dotnet"
          test_dir = File.join(dir, "Tests")
          FileUtils.mkdir_p(test_dir)
          namespace = name.gsub(/[^a-zA-Z0-9]+/, "")

          File.write(File.join(test_dir, "HandlerTests.cs"), <<~CSHARP)
            using Xunit;
            using System.Collections.Generic;

            namespace #{namespace}.Tests;

            public class HandlerTests
            {
                [Fact]
                public void HandleBeforeTransition_ReturnsValidResponse()
                {
                    var payload = new Dictionary<string, object>
                    {
                        { "event_type", "before_transition" }
                    };

                    // Test payload structure
                    Assert.Equal("before_transition", payload["event_type"]);
                }

                [Fact]
                public void HandleAfterTransition_ReturnsValidResponse()
                {
                    var payload = new Dictionary<string, object>
                    {
                        { "event_type", "after_transition" }
                    };

                    Assert.Equal("after_transition", payload["event_type"]);
                }
            }
          CSHARP

          File.write(File.join(test_dir, "Tests.csproj"), <<~XML)
            <Project Sdk="Microsoft.NET.Sdk">

              <PropertyGroup>
                <TargetFramework>net8.0</TargetFramework>
                <ImplicitUsings>enable</ImplicitUsings>
                <Nullable>enable</Nullable>
                <IsPackable>false</IsPackable>
              </PropertyGroup>

              <ItemGroup>
                <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.8.0" />
                <PackageReference Include="xunit" Version="2.6.2" />
                <PackageReference Include="xunit.runner.visualstudio" Version="2.5.4" />
              </ItemGroup>

              <ItemGroup>
                <ProjectReference Include="../Extension.csproj" />
              </ItemGroup>

            </Project>
          XML

        when "go"
          File.write(File.join(dir, "main_test.go"), <<~GO)
            package main

            import (
                "testing"
            )

            func TestHandleBeforeTransition(t *testing.T) {
                payload := map[string]interface{}{
                    "event_type": "before_transition",
                }

                if payload["event_type"] != "before_transition" {
                    t.Error("Expected event_type to be before_transition")
                }
            }

            func TestHandleAfterTransition(t *testing.T) {
                payload := map[string]interface{}{
                    "event_type": "after_transition",
                }

                if payload["event_type"] != "after_transition" {
                    t.Error("Expected event_type to be after_transition")
                }
            }
          GO
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

        when "java"
          File.write(File.join(workflows_dir, "test.yml"), <<~YAML)
            name: Test

            on: [push, pull_request]

            jobs:
              test:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - uses: actions/setup-java@v4
                    with:
                      distribution: 'temurin'
                      java-version: '21'
                      cache: 'maven'
                  - run: mvn test -B
          YAML

        when "dotnet"
          File.write(File.join(workflows_dir, "test.yml"), <<~YAML)
            name: Test

            on: [push, pull_request]

            jobs:
              test:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - uses: actions/setup-dotnet@v4
                    with:
                      dotnet-version: '8.0.x'
                  - run: dotnet restore
                  - run: dotnet build --no-restore
                  - run: dotnet test --no-build
          YAML

        when "go"
          File.write(File.join(workflows_dir, "test.yml"), <<~YAML)
            name: Test

            on: [push, pull_request]

            jobs:
              test:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - uses: actions/setup-go@v5
                    with:
                      go-version: '1.23'
                  - run: go mod download
                  - run: go test -v ./...
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
        def custom_data_scope_params
          project_id = options[:project]
          project_key = options[:project_key]

          if project_id.nil? && project_key.nil?
            error "Provide --project or --project-key"
            exit 1
          end

          params = {}
          params[:project_id] = project_id if project_id
          params[:project_key] = project_key if project_key
          params
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

            # Only accept string format: module: "module_id"
            module_value = data["module"]

            if module_value.nil?
              errors << "#{relative_to_repo(file)} missing 'module:' field"
              next
            end

            unless module_value.is_a?(String)
              errors << "#{relative_to_repo(file)} 'module:' must be a string, not a hash"
              next
            end

            module_id = module_value

            # Validate module ID format
            unless module_id.match?(/^[a-z][a-z0-9.-]+$/)
              warnings << "#{relative_to_repo(file)} module ID should use lowercase with dots (e.g., dev.kiket.ext.myextension.data)"
            end

            # Tables must be at root level
            tables = data["tables"]
            if tables.nil? || (tables.is_a?(Hash) && tables.empty?) || (tables.is_a?(Array) && tables.empty?)
              errors << "#{relative_to_repo(file)} must define at least one table"
            end

            local_modules[module_id] = file
          rescue Psych::SyntaxError => e
            errors << "Invalid YAML in #{relative_to_repo(file)}: #{e.message}"
          end

          permissions = Array(manifest.dig("extension", "custom_data", "permissions"))
          permissions.each do |entry|
            module_id = entry["module"] || entry[:module]
            next unless module_id

            ops = Array(entry["operations"] || entry[:operations]).map(&:to_s)
            invalid = ops.reject { |op| %w[read write delete admin].include?(op) }
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

        def validate_wizard_setup(manifest)
          errors = []
          warnings = []

          setup_steps = manifest.dig("extension", "setup") || manifest["setup"]
          return { errors: errors, warnings: warnings } if setup_steps.nil? || setup_steps.empty?

          setup_steps.each_with_index do |step, index|
            step_num = index + 1
            step_type = step.keys.first
            step_config = step[step_type]

            unless VALID_STEP_TYPES.include?(step_type)
              errors << "Step #{step_num}: Invalid step type '#{step_type}'. Valid: #{VALID_STEP_TYPES.join(", ")}"
              next
            end

            # Validate step configuration
            case step_type
            when "secrets"
              # Support both direct fields and collect (reference to configuration keys)
              fields = step_config["fields"] || []
              collect_keys = step_config["collect"] || []

              if fields.empty? && collect_keys.empty?
                errors << "Step #{step_num} (secrets): Must define 'fields' or 'collect'"
              end

              # Validate inline fields
              fields.each do |field|
                errors << "Step #{step_num} (secrets): Field missing required 'key'" unless field["key"]

                obtain_type = field.dig("obtain", "type")
                if obtain_type && !VALID_OBTAIN_TYPES.include?(obtain_type)
                  errors << "Step #{step_num}: Invalid obtain type '#{obtain_type}'. Valid: #{VALID_OBTAIN_TYPES.join(", ")}"
                end

                # OAuth fields require authorization_url and token_url
                next unless %w[oauth2 oauth2_client_credentials].include?(obtain_type)

                unless field.dig("obtain", "authorization_url")
                  errors << "Step #{step_num}: OAuth field '#{field["key"]}' missing authorization_url"
                end
                unless field.dig("obtain", "token_url")
                  errors << "Step #{step_num}: OAuth field '#{field["key"]}' missing token_url"
                end
              end

              # Validate collect references against configuration
              if collect_keys.any?
                config_keys = extract_config_keys(manifest)

                collect_keys.each do |key|
                  unless config_keys.include?(key)
                    warnings << "Step #{step_num} (secrets): collect references '#{key}' not found in configuration"
                  end
                end
              end

            when "configure"
              # Support both direct fields and collect (reference to configuration keys)
              fields = step_config["fields"] || []
              collect_keys = step_config["collect"] || []

              if fields.empty? && collect_keys.empty?
                warnings << "Step #{step_num} (configure): No fields or collect defined"
              end

              # Validate inline fields
              fields.each do |field|
                errors << "Step #{step_num} (configure): Field missing required 'key'" unless field["key"]

                # Validate showWhen references
                if field["showWhen"]
                  show_when = field["showWhen"]
                  ref_field = show_when["field"]
                  unless fields.any? { |f| f["key"] == ref_field }
                    warnings << "Step #{step_num}: showWhen references unknown field '#{ref_field}'"
                  end
                end

                # Validate select options
                if field["type"] == "select" && (field["options"].nil? || field["options"].empty?)
                  errors << "Step #{step_num}: Select field '#{field["key"]}' must have options"
                end
              end

              # Validate collect references against configuration
              if collect_keys.any?
                config_keys = extract_config_keys(manifest)

                collect_keys.each do |key|
                  unless config_keys.include?(key)
                    warnings << "Step #{step_num} (configure): collect references '#{key}' not found in configuration"
                  end
                end
              end

            when "test"
              unless step_config["action"]
                warnings << "Step #{step_num} (test): No action defined - step will be skipped"
              end

            when "info"
              unless step_config["content"] || step_config["title"]
                warnings << "Step #{step_num} (info): No content or title defined"
              end

              (step_config["links"] || []).each do |link|
                unless link["url"] && link["label"]
                  errors << "Step #{step_num} (info): Links must have 'url' and 'label'"
                end
              end
            end
          end

          { errors: errors, warnings: warnings }
        end

        # Extract configuration keys from hash format only
        # Hash format: { FOO: { type: "string" }, BAR: { type: "string" } }
        def extract_config_keys(manifest)
          config = manifest.dig("extension", "configuration")
          return [] unless config.is_a?(Hash)

          config.keys.map(&:to_s)
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
                      input = $stdin.read
                      raise ArgumentError, "No payload provided (pass --payload or pipe data)" if input.strip.empty?

                      MultiJson.load(input)
                    end

          secrets = {}
          secrets.merge!(load_env_file(opts[:env_file])) if present?(opts[:env_file])

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
