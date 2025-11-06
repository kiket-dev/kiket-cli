# frozen_string_literal: true

require_relative "base"
require "yaml"

module Kiket
  module Commands
    class Workflows < Base
      desc "lint [PATH]", "Validate workflow definitions"
      option :fix, type: :boolean, desc: "Auto-fix formatting issues"
      def lint(path = ".")
        workflow_files = Dir.glob(File.join(path, "**/*.{yaml,yml}"))

        if workflow_files.empty?
          error "No workflow files found"
          exit 1
        end

        errors = []
        warnings = []
        fixed = []

        workflow_files.each do |file|
          info "Checking #{file}..." if verbose?

          begin
            content = File.read(file)
            workflow = YAML.safe_load(content)

            # Validate structure
            unless workflow.is_a?(Hash)
              errors << "#{file}: Invalid YAML structure"
              next
            end

            # Check required fields
            errors << "#{file}: Missing model_version" unless workflow["model_version"]
            errors << "#{file}: Missing workflow name" unless workflow.dig("workflow", "name")

            # Check states
            if workflow.dig("workflow", "states")
              states = workflow.dig("workflow", "states")
              errors << "#{file}: States must be a hash" unless states.is_a?(Hash)

              states&.each do |state_name, state_def|
                unless state_def.is_a?(Hash)
                  errors << "#{file}: State '#{state_name}' must be a hash"
                  next
                end

                # Validate transitions
                next unless state_def["transitions"]

                state_def["transitions"].each do |transition|
                  errors << "#{file}: Transition missing 'to' field in state '#{state_name}'" unless transition["to"]
                end
              end
            end

            # Check for common issues
            warnings << "#{file}: No description provided" unless workflow.dig("workflow", "description")
            warnings << "#{file}: No initial state defined" unless workflow.dig("workflow", "initial_state")

            # Auto-fix formatting if requested
            if options[:fix]
              formatted = YAML.dump(workflow)
              if formatted != content
                File.write(file, formatted)
                fixed << file
              end
            end
          rescue Psych::SyntaxError => e
            errors << "#{file}: YAML syntax error - #{e.message}"
          end
        end

        puts "\nResults:"
        puts "  Files checked: #{workflow_files.size}"
        puts "  #{pastel.green("✓ Valid: #{workflow_files.size - errors.size}")}"
        puts "  #{pastel.red("✗ Errors: #{errors.size}")}" if errors.any?
        puts "  #{pastel.yellow("⚠ Warnings: #{warnings.size}")}" if warnings.any?
        puts "  #{pastel.blue("✎ Fixed: #{fixed.size}")}" if fixed.any?

        if errors.any?
          puts "\nErrors:"
          errors.each { |err| puts "  #{err}" }
          exit 1
        end

        if warnings.any?
          puts "\nWarnings:"
          warnings.each { |warn| puts "  #{warn}" }
        end

        success "Workflow validation complete"
      rescue StandardError => e
        handle_error(e)
      end

      desc "test [PATH]", "Test workflow definitions"
      option :scenario, type: :string, desc: "Path to scenario file"
      def test(path = ".")
        ensure_authenticated!

        workflow_files = Dir.glob(File.join(path, "**/*.{yaml,yml}"))

        if workflow_files.empty?
          error "No workflow files found"
          exit 1
        end

        info "Running workflow tests..."

        workflow_files.each do |file|
          spinner = spinner("Testing #{File.basename(file)}...")
          spinner.auto_spin

          begin
            workflow_content = File.read(file)

            # If scenario file provided, use it
            test_payload = if options[:scenario]
                             YAML.load_file(options[:scenario])
                           else
                             generate_test_payload(YAML.safe_load(workflow_content))
                           end

            # Send to API for validation
            response = client.post("/api/v1/workflows/validate",
                                   body: {
                                     workflow: workflow_content,
                                     test_payload: test_payload
                                   })

            if response["valid"]
              spinner.success
            else
              spinner.error
              error "#{file}: #{response["errors"].join(", ")}"
            end
          rescue StandardError => e
            spinner.error
            error "#{file}: #{e.message}"
          end
        end

        success "Workflow tests complete"
      rescue StandardError => e
        handle_error(e)
      end

      desc "simulate WORKFLOW", "Simulate workflow execution"
      option :input, type: :string, required: true, desc: "Path to input payload JSON"
      def simulate(workflow_path)
        ensure_authenticated!

        unless File.exist?(workflow_path)
          error "Workflow file not found: #{workflow_path}"
          exit 1
        end

        unless File.exist?(options[:input])
          error "Input file not found: #{options[:input]}"
          exit 1
        end

        workflow_content = File.read(workflow_path)
        input_payload = JSON.parse(File.read(options[:input]))

        spinner = spinner("Simulating workflow execution...")
        spinner.auto_spin

        response = client.post("/api/v1/workflows/simulate",
                               body: {
                                 workflow: workflow_content,
                                 payload: input_payload
                               })

        spinner.success("Simulation complete")

        puts "\n#{pastel.bold("Execution Path:")}"
        response["execution"]["states_visited"].each_with_index do |state, idx|
          puts "  #{idx + 1}. #{state}"
        end

        puts "\n#{pastel.bold("Actions Executed:")}"
        response["execution"]["actions"].each do |action|
          puts "  • #{action["type"]}: #{action["description"]}"
        end

        if response["execution"]["errors"]&.any?
          puts "\n#{pastel.bold("Errors:")}"
          response["execution"]["errors"].each do |error|
            puts "  #{pastel.red("✗")} #{error}"
          end
        end

        puts "\n#{pastel.bold("Final State:")} #{response["execution"]["final_state"]}"
      rescue JSON::ParserError => e
        error "Invalid JSON in input file: #{e.message}"
        exit 1
      rescue StandardError => e
        handle_error(e)
      end

      desc "visualize WORKFLOW", "Generate workflow diagram"
      option :output, type: :string, default: "workflow.svg", desc: "Output file path"
      option :format, type: :string, default: "svg", enum: %w[svg png pdf], desc: "Output format"
      def visualize(workflow_path)
        ensure_authenticated!

        unless File.exist?(workflow_path)
          error "Workflow file not found: #{workflow_path}"
          exit 1
        end

        workflow_content = File.read(workflow_path)

        spinner = spinner("Generating visualization...")
        spinner.auto_spin

        response = client.post("/api/v1/workflows/visualize",
                               body: {
                                 workflow: workflow_content,
                                 format: options[:format]
                               })

        spinner.success("Visualization generated")

        # Save diagram
        require "base64"
        diagram_data = Base64.decode64(response["diagram"])
        File.binwrite(options[:output], diagram_data)

        success "Workflow diagram saved to #{options[:output]}"
      rescue StandardError => e
        handle_error(e)
      end

      desc "diff", "Compare workflows against another branch/tag"
      option :against, type: :string, required: true, desc: "Branch or tag to compare against"
      option :path, type: :string, default: ".", desc: "Path to workflow repository"
      def diff
        path = options[:path]

        unless Dir.exist?(File.join(path, ".git"))
          error "Not a git repository: #{path}"
          exit 1
        end

        spinner = spinner("Comparing workflows...")
        spinner.auto_spin

        require "open3"
        cmd = "git -C #{path} diff #{options[:against]} --name-only -- '*.yaml' '*.yml'"
        stdout, stderr, status = Open3.capture3(cmd)

        unless status.success?
          spinner.error
          error "Git diff failed: #{stderr}"
          exit 1
        end

        changed_files = stdout.split("\n")

        if changed_files.empty?
          spinner.success("No workflow changes")
          info "No workflow files changed"
          return
        end

        spinner.success("Found #{changed_files.size} changed files")

        puts "\n#{pastel.bold("Changed Workflows:")}"
        changed_files.each do |file|
          # Get diff stats
          cmd = "git -C #{path} diff #{options[:against]} --stat -- #{file}"
          stats, = Open3.capture2(cmd)

          puts "  #{pastel.yellow("~")} #{file}"
          puts "    #{stats.strip}" if verbose?
        end
      rescue StandardError => e
        handle_error(e)
      end

      private

      def generate_test_payload(workflow)
        # Generate basic test payload from workflow definition
        initial_state = workflow.dig("workflow", "initial_state")

        {
          "event_type" => "transition_requested",
          "from_state" => initial_state,
          "to_state" => workflow.dig("workflow", "states", initial_state, "transitions", 0, "to"),
          "issue" => {
            "id" => "test-issue-123",
            "title" => "Test Issue"
          }
        }
      end
    end
  end
end
