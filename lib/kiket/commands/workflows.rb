# frozen_string_literal: true

require_relative "base"
require "yaml"
require "json"
require "time"

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

            # Skip non-workflow YAML files
            next unless workflow["model_version"] || workflow["workflow"] || workflow["states"]

            # Check required fields
            errors << "#{file}: Missing model_version" unless workflow["model_version"]
            errors << "#{file}: Missing workflow name" unless workflow.dig("workflow", "name")

            # Check states (top-level or under workflow key)
            states = workflow["states"] || workflow.dig("workflow", "states")
            if states
              errors << "#{file}: States must be a hash" unless states.is_a?(Hash)

              has_initial = false
              has_final = false

              states&.each do |state_name, state_def|
                unless state_def.is_a?(Hash)
                  errors << "#{file}: State '#{state_name}' must be a hash"
                  next
                end

                has_initial = true if %w[initial trigger].include?(state_def["type"])
                has_final = true if state_def["type"] == "final"

                # Validate SLA config
                if state_def["sla"].is_a?(Hash)
                  sla = state_def["sla"]
                  validate_sla_duration(file, state_name, "warning", sla["warning"], errors)
                  validate_sla_duration(file, state_name, "breach", sla["breach"], errors)

                  if sla["business_hours"] && ![true, false].include?(sla["business_hours"]) # rubocop:disable Rails/NegateInclude
                    errors << "#{file}: State '#{state_name}' SLA business_hours must be true/false"
                  end

                  # Validate on_warning / on_breach hooks
                  validate_lifecycle_hooks(file, state_name, "on_warning", sla["on_warning"], errors, warnings)
                  validate_lifecycle_hooks(file, state_name, "on_breach", sla["on_breach"], errors, warnings)
                end

                # Validate lifecycle hooks
                validate_lifecycle_hooks(file, state_name, "on_enter", state_def["on_enter"], errors, warnings)
                validate_lifecycle_hooks(file, state_name, "on_exit", state_def["on_exit"], errors, warnings)

                # Validate approval config
                next unless state_def["approval"].is_a?(Hash)

                approval = state_def["approval"]
                errors << "#{file}: State '#{state_name}' approval.required must be a number" unless approval["required"].is_a?(Integer)
                errors << "#{file}: State '#{state_name}' approval.approvers must be an array" unless approval["approvers"].is_a?(Array)
              end

              warnings << "#{file}: No initial or trigger state defined" unless has_initial || (states&.size || 0).zero?
              warnings << "#{file}: No final state defined" unless has_final || (states&.size || 0).zero?
            end

            # Check transitions
            transitions = workflow["transitions"] || workflow.dig("workflow", "transitions")
            if transitions.is_a?(Array)
              transitions.each_with_index do |t, i|
                errors << "#{file}: Transition ##{i + 1} missing 'from'" unless t["from"]
                errors << "#{file}: Transition ##{i + 1} missing 'to'" unless t["to"]

                # Validate transition conditions
                next unless t["conditions"].is_a?(Array)

                t["conditions"].each_with_index do |cond, ci|
                  errors << "#{file}: Transition ##{i + 1} condition ##{ci + 1} missing 'field'" unless cond["field"]
                  errors << "#{file}: Transition ##{i + 1} condition ##{ci + 1} missing 'operator'" unless cond["operator"]
                  valid_ops = %w[equals not_equals contains gt lt is_empty is_not_empty]
                  if cond["operator"] && !valid_ops.include?(cond["operator"]) # rubocop:disable Rails/NegateInclude
                    warnings << "#{file}: Transition ##{i + 1} condition ##{ci + 1} unknown operator '#{cond["operator"]}'"
                  end
                end
              end
            end

            # Check for common issues
            warnings << "#{file}: No description provided" unless workflow.dig("workflow", "description")

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
        puts("  Files checked: #{workflow_files.size}")
        puts("  #{pastel.green("✓ Valid: #{workflow_files.size - errors.size}")}")
        puts("  #{pastel.red("✗ Errors: #{errors.size}")}") if errors.any?
        puts("  #{pastel.yellow("⚠ Warnings: #{warnings.size}")}") if warnings.any?
        puts("  #{pastel.blue("✎ Fixed: #{fixed.size}")}") if fixed.any?

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

      no_commands do
        def validate_sla_duration(file, state_name, field, value, errors)
          return if value.nil? || value.to_s.empty?

          return if value.to_s.match?(/\A\d+(m|h|d)\z/)

          errors << "#{file}: State '#{state_name}' SLA #{field} '#{value}' invalid — use format like 24h, 7d, 30m"
        end

        def validate_lifecycle_hooks(file, state_name, hook_name, hooks, errors, warnings)
          return unless hooks.is_a?(Array)

          valid_actions = %w[notify ai_analyze webhook blockchain_anchor transition assign spawn_issue spawn_form]

          hooks.each_with_index do |hook, i|
            unless hook.is_a?(Hash)
              errors << "#{file}: State '#{state_name}' #{hook_name}[#{i}] must be a hash"
              next
            end

            unless hook["action"] && !hook["action"].empty?
              errors << "#{file}: State '#{state_name}' #{hook_name}[#{i}] missing 'action'"
              next
            end

            action_name = hook["action"]
            unless valid_actions.include?(action_name) || action_name.start_with?("ext:")
              warnings << "#{file}: State '#{state_name}' #{hook_name}[#{i}] unknown action '#{action_name}' (may be an extension action)"
            end

            # Validate spawn_issue has template
            if hook["action"] == "spawn_issue" && (hook.dig("metadata", "template").nil? || hook.dig("metadata", "template").to_s.empty?)
              warnings << "#{file}: State '#{state_name}' #{hook_name}[#{i}] spawn_issue missing metadata.template"
            end
          end
        end
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

        puts("\n#{pastel.bold("Execution Path:")}")
        response["execution"]["states_visited"].each_with_index do |state, idx|
          puts "  #{idx + 1}. #{state}"
        end

        puts("\n#{pastel.bold("Actions Executed:")}")
        response["execution"]["actions"].each do |action|
          puts "  • #{action["type"]}: #{action["description"]}"
        end

        if response["execution"]["errors"]&.any?
          puts("\n#{pastel.bold("Errors:")}")
          response["execution"]["errors"].each do |error|
            puts "  #{pastel.red("✗")} #{error}"
          end
        end

        puts("\n#{pastel.bold("Final State:")} #{response["execution"]["final_state"]}")
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
        stdout, stderr, status = Open3.capture3("git", "-C", path, "diff", options[:against], "--name-only", "--",
                                                "*.yaml", "*.yml")

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

        puts("\n#{pastel.bold("Changed Workflows:")}")
        changed_files.each do |file|
          # Get diff stats
          stats, = Open3.capture2("git", "-C", path, "diff", options[:against], "--stat", "--", file)

          puts("  #{pastel.yellow("~")} #{file}")
          puts("    #{stats.strip}") if verbose?
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "generate-schema [PATH]", "Produce a JSON schema summary for workflows"
      option :output, type: :string, default: "workflow_schema.json", desc: "Output file"
      def generate_schema(path = ".")
        workflow_files = if File.directory?(path)
                           Dir.glob(File.join(path, "**/*.{yml,yaml}"))
                         else
                           [path]
                         end
        workflow_files = workflow_files.select { |file| File.file?(file) }

        if workflow_files.empty?
          error "No workflow files found"
          exit 1
        end

        schema = {
          generated_at: Time.now.utc.iso8601,
          workflows: []
        }

        workflow_files.each do |file|
          data = begin
            YAML.safe_load_file(file)
          rescue StandardError
            nil
          end
          next unless data.is_a?(Hash) && data["workflow"]

          workflow = data["workflow"]
          states = workflow["states"] || {}
          transitions = states.flat_map do |state_name, state_def|
            Array(state_def["transitions"]).filter_map do |transition|
              next unless transition.is_a?(Hash)

              {
                "from" => state_name,
                "to" => transition["to"],
                "guard" => transition["guard"],
                "action" => transition["action"]
              }.compact
            end
          end

          schema[:workflows] << {
            "name" => workflow["name"] || File.basename(file, File.extname(file)),
            "file" => file,
            "states" => states.keys,
            "transitions" => transitions
          }
        end

        File.write(options[:output], JSON.pretty_generate(schema))
        success "Schema written to #{options[:output]}"
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
