# frozen_string_literal: true

require_relative "base"
require "fileutils"

module Kiket
  module Commands
    class Extensions < Base
      desc "scaffold NAME", "Generate a new extension project"
      option :sdk, type: :string, default: "python", desc: "SDK language (python, typescript, ruby)"
      option :manifest, type: :boolean, desc: "Generate manifest only"
      option :template, type: :string, desc: "Template type (webhook_guard, outbound_integration, notification_pack)"
      def scaffold(name)
        ensure_authenticated!

        template_type = options[:template] || prompt.select("Select extension template:", %w[
          webhook_guard
          outbound_integration
          notification_pack
          custom
        ])

        sdk = options[:sdk]
        dir = File.join(Dir.pwd, name)

        if File.exist?(dir)
          error "Directory #{name} already exists"
          exit 1
        end

        spinner = spinner("Generating extension project...")
        spinner.auto_spin

        FileUtils.mkdir_p(dir)

        # Generate manifest
        generate_manifest(dir, name, template_type)

        # Generate SDK-specific files
        case sdk
        when "python"
          generate_python_extension(dir, name, template_type)
        when "typescript"
          generate_typescript_extension(dir, name, template_type)
        when "ruby"
          generate_ruby_extension(dir, name, template_type)
        end

        # Generate common files
        generate_readme(dir, name, sdk)
        generate_gitignore(dir)
        generate_tests(dir, sdk, template_type)
        generate_github_actions(dir, sdk)

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
          system("cd #{path} && ruff check . #{options[:fix] ? '--fix' : ''}")
        elsif File.exist?(File.join(path, "package.json"))
          info "Running TypeScript linting..."
          system("cd #{path} && npm run lint #{options[:fix] ? '-- --fix' : ''}")
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

      desc "package [PATH]", "Package extension for distribution"
      option :output, type: :string, desc: "Output path for package"
      def package(path = ".")
        ensure_authenticated!

        manifest_path = File.join(path, ".kiket", "manifest.yaml")

        unless File.exist?(manifest_path)
          error "No manifest.yaml found"
          exit 1
        end

        require "yaml"
        manifest = YAML.load_file(manifest_path)
        extension_id = manifest.dig("extension", "id")
        version = manifest.dig("extension", "version") || "1.0.0"

        output_file = options[:output] || "#{extension_id}-#{version}.tar.gz"

        spinner = spinner("Packaging extension...")
        spinner.auto_spin

        # Create tarball
        files_to_package = [
          ".kiket/manifest.yaml",
          "README.md",
          "src/**/*",
          "lib/**/*",
          "handlers/**/*"
        ]

        require "open3"
        cmd = "tar -czf #{output_file} -C #{path} #{files_to_package.join(' ')}"
        stdout, stderr, status = Open3.capture3(cmd)

        if status.success?
          spinner.success("Package created")
          success "Extension packaged: #{output_file}"
          info "Size: #{File.size(output_file) / 1024} KB"
        else
          spinner.error("Packaging failed")
          error stderr
          exit 1
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "publish [PATH]", "Publish extension to marketplace"
      option :registry, type: :string, default: "marketplace", desc: "Registry name"
      option :dry_run, type: :boolean, desc: "Validate without publishing"
      def publish(path = ".")
        ensure_authenticated!

        manifest_path = File.join(path, ".kiket", "manifest.yaml")

        unless File.exist?(manifest_path)
          error "No manifest.yaml found"
          exit 1
        end

        # Run lint first
        invoke :lint, [path]

        # Run tests
        info "Running tests before publish..."
        invoke :test, [path]

        require "yaml"
        manifest = YAML.load_file(manifest_path)

        puts pastel.bold("\nPublish Extension:")
        puts "  ID: #{manifest.dig('extension', 'id')}"
        puts "  Name: #{manifest.dig('extension', 'name')}"
        puts "  Version: #{manifest.dig('extension', 'version')}"
        puts ""

        if options[:dry_run]
          info "Dry run - skipping actual publish"
          return
        end

        return unless prompt.yes?("Publish to #{options[:registry]}?")

        # Package first
        invoke :package, [path], output: "/tmp/extension-package.tar.gz"

        spinner = spinner("Publishing extension...")
        spinner.auto_spin

        # Upload package
        File.open("/tmp/extension-package.tar.gz", "rb") do |file|
          response = client.post("/api/v1/extensions/registry/#{options[:registry]}/publish",
                                  body: {
                                    manifest: manifest,
                                    package: Base64.strict_encode64(file.read)
                                  })

          spinner.success("Published")
          success "Extension published successfully"
          info "Registry: #{options[:registry]}"
          info "Version: #{response['version']}"
        end
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

            if manifest.dig("extension", "id")
              checks << { name: "Extension ID", status: :ok, message: manifest.dig("extension", "id") }
            else
              checks << { name: "Extension ID", status: :error, message: "Missing" }
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
        if test_files.any?
          checks << { name: "Tests", status: :ok, message: "#{test_files.size} test files found" }
        else
          checks << { name: "Tests", status: :warning, message: "No test files found" }
        end

        # Check for documentation
        if File.exist?(File.join(path, "README.md"))
          checks << { name: "Documentation", status: :ok, message: "README.md present" }
        else
          checks << { name: "Documentation", status: :warning, message: "No README.md" }
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

      private

      def generate_manifest(dir, name, template_type)
        manifest_dir = File.join(dir, ".kiket")
        FileUtils.mkdir_p(manifest_dir)

        manifest = {
          "model_version" => "1.0",
          "extension" => {
            "id" => name.downcase.tr(" ", "_"),
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
          ["after_transition", "issue_created", "issue_updated"]
        else
          []
        end
      end

      def generate_python_extension(dir, name, template_type)
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
              name="#{name.tr(' ', '_').downcase}",
              version="1.0.0",
              packages=find_packages(where="src"),
              package_dir={"": "src"},
              install_requires=[
                  "kiket-sdk>=0.1.0",
              ],
          )
        SETUP
      end

      def generate_typescript_extension(dir, name, template_type)
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
            "name": "#{name.tr(' ', '-').downcase}",
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
              "typescript": "^5.0.0",
              "jest": "^29.0.0",
              "@typescript-eslint/eslint-plugin": "^6.0.0",
              "eslint": "^8.0.0"
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

      def generate_ruby_extension(dir, name, template_type)
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

      def generate_tests(dir, sdk, template_type)
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
        end
      end
    end
  end
end
