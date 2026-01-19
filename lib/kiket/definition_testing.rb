# frozen_string_literal: true

require "yaml"
require "json"
require "open3"
require "time"

module Kiket
  module DefinitionTesting
    Result = Struct.new(:category, :file, :message, :severity, :metadata, keyword_init: true) do
      def to_h
        {
          category: category,
          file: file,
          message: message,
          severity: severity,
          metadata: metadata || {}
        }
      end
    end

    class Harness
      def initialize(root:, include_workflows: true, include_dashboards: true, include_dbt: true, include_projects: true,
                     include_inbound_email: true, include_issue_types: true, dbt_project_path: nil, run_dbt_cli: true)
        @root = File.expand_path(root)
        @include_workflows = include_workflows
        @include_dashboards = include_dashboards
        @include_dbt = include_dbt
        @include_projects = include_projects
        @include_inbound_email = include_inbound_email
        @include_issue_types = include_issue_types
        @dbt_project_path = dbt_project_path || default_dbt_project
        @run_dbt_cli = run_dbt_cli
      end

      def run
        results = []
        results.concat(ProjectLinter.new(@root).lint) if @include_projects
        results.concat(WorkflowLinter.new(@root).lint) if @include_workflows
        results.concat(IssueTypesLinter.new(@root).lint) if @include_issue_types
        results.concat(DashboardLinter.new(@root).lint) if @include_dashboards
        results.concat(InboundEmailLinter.new(@root).lint) if @include_inbound_email
        if @include_dbt
          results.concat(DbtLinter.new(@root, project_path: @dbt_project_path, run_cli: @run_dbt_cli).lint)
        end
        results
      end

      private

      def default_dbt_project
        project_candidate = File.join(@root, "analytics", "dbt")
        return project_candidate if Dir.exist?(project_candidate)

        # Fall back to root-level analytics project if invoked from repo root
        repo_candidate = File.expand_path(File.join(__dir__, "..", "..", "analytics", "dbt"))
        Dir.exist?(repo_candidate) ? repo_candidate : nil
      end
    end

    class ProjectLinter
      def initialize(root)
        @root = root
      end

      def lint
        files = Dir.glob(File.join(@root, "**", ".kiket", "project.y{a}ml"))
        return [info_result("projects", nil, "No project.yaml files found")] if files.empty?

        files.flat_map { |file| lint_file(file) }
      end

      private

      def lint_file(file)
        data = load_yaml(file)
        return [data] if data.is_a?(Result) # error result

        results = []

        return [error_result("projects", file, "YAML document must be an object")] unless data.is_a?(Hash)

        model_version = data["model_version"]
        results << error_result("projects", file, "Missing model_version") unless model_version

        project = data["project"]
        return results + [error_result("projects", file, "Missing project root key")] unless project.is_a?(Hash)

        %w[id name].each do |field|
          results << error_result("projects", file, "project.#{field} is required") if project[field].to_s.strip.empty?
        end

        # Validate team roles are defined
        team = project["team"]
        if team.nil? || !team.is_a?(Hash)
          results << warning_result("projects", file, "project.team section is not defined; consider adding team roles")
        else
          roles = team["roles"]
          if roles.nil? || !roles.is_a?(Array) || roles.empty?
            results << warning_result("projects", file,
                                      "project.team.roles is not defined; role dropdowns will fall back to 'member'")
          else
            roles.each_with_index do |role, idx|
              unless role.is_a?(Hash)
                results << error_result("projects", file, "Role ##{idx + 1} must be a mapping with 'name' field")
                next
              end

              name = role["name"]
              if name.to_s.strip.empty?
                results << error_result("projects", file, "Role ##{idx + 1} missing 'name' field")
              elsif !name.to_s.match?(/\A[a-zA-Z][a-zA-Z0-9_-]{0,49}\z/)
                results << error_result("projects", file,
                                        "Role '#{name}' has invalid format; must start with letter, contain only letters/numbers/underscores/hyphens, max 50 chars")
              end
            end
          end
        end

        results.empty? ? [success_result("projects", file, "Project lint passed")] : results
      end

      def load_yaml(file)
        YAML.safe_load_file(file, aliases: true) || {}
      rescue Psych::SyntaxError => e
        error_result("projects", file, "YAML syntax error: #{e.message}")
      end

      def error_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :error)
      end

      def warning_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :warning)
      end

      def info_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :info)
      end

      def success_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :success)
      end
    end

    class WorkflowLinter
      def initialize(root)
        @root = root
      end

      def lint
        files = Dir.glob(File.join(@root, "**", ".kiket", "workflows", "**", "*.y{a}ml"))
        return [info_result("workflows", nil, "No workflow files found")] if files.empty?

        files.flat_map { |file| lint_file(file) }
      end

      private

      def lint_file(file)
        data = load_yaml(file)
        return [data] if data.is_a?(Result) # error result

        if data.is_a?(Hash) && data.key?("recipe")
          return [info_result("workflows", file, "Skipped automation recipe definition")]
        end

        results = []

        return [error_result("workflows", file, "YAML document must be an object")] unless data.is_a?(Hash)

        model_version = data["model_version"] || data.dig("workflow", "model_version")
        results << error_result("workflows", file, "Missing model_version") unless model_version

        workflow = data["workflow"] || {}
        name = workflow["name"]
        results << error_result("workflows", file, "Missing workflow.name") if name.to_s.strip.empty?

        # Recommend workflow.id for multi-workflow support
        workflow_id = workflow["id"]
        if workflow_id.to_s.strip.empty?
          results << warning_result("workflows", file,
                                    "Missing workflow.id; recommended for multi-workflow support")
        elsif !workflow_id.to_s.match?(/\A[a-z][a-z0-9_-]*\z/)
          results << error_result("workflows", file,
                                  "workflow.id '#{workflow_id}' invalid; must be lowercase alphanumeric with hyphens/underscores")
        end

        states = data["states"] || workflow["states"]
        case states
        when Hash
          if states.empty?
            results << error_result("workflows", file, "Workflow must define at least one state")
          else
            states.each do |state_name, config|
              unless config.is_a?(Hash)
                results << error_result("workflows", file, "State '#{state_name}' must be a mapping")
                next
              end

              type = config["type"]
              results << error_result("workflows", file, "State '#{state_name}' missing type") if type.to_s.strip.empty?
            end
          end
        when Array
          if states.empty?
            results << error_result("workflows", file, "Workflow must define at least one state")
          else
            states.each_with_index do |state, idx|
              unless state.is_a?(Hash)
                results << error_result("workflows", file, "State ##{idx + 1} must be a mapping")
                next
              end

              key = state["key"] || state["name"]
              results << error_result("workflows", file, "State ##{idx + 1} missing key/name") if key.to_s.strip.empty?
            end
          end
        else
          results << error_result("workflows", file, "Workflow must define at least one state")
        end

        transitions = data["transitions"] || workflow["transitions"] || []
        if transitions.empty?
          results << warning_result("workflows", file, "Workflow defines no transitions")
        else
          transitions.each_with_index do |transition, idx|
            unless transition.is_a?(Hash)
              results << error_result("workflows", file, "Transition ##{idx + 1} must be a mapping")
              next
            end

            from = transition["from"]
            to = transition["to"]
            if from.to_s.strip.empty?
              results << error_result("workflows", file,
                                      "Transition ##{idx + 1} missing 'from'")
            end
            results << error_result("workflows", file, "Transition ##{idx + 1} missing 'to'") if to.to_s.strip.empty?
          end
        end

        results.empty? ? [success_result("workflows", file, "Workflow lint passed")] : results
      end

      def load_yaml(file)
        YAML.safe_load_file(file, aliases: true) || {}
      rescue Psych::SyntaxError => e
        error_result("workflows", file, "YAML syntax error: #{e.message}")
      end

      def error_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :error)
      end

      def warning_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :warning)
      end

      def info_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :info)
      end

      def success_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :success)
      end
    end

    class IssueTypesLinter
      VALID_COLORS = %w[primary secondary success danger warning info light dark purple
                        blue green red yellow orange gray grey].freeze
      VALID_ICONS = %w[bookmark flag bug check-square lightning diagram-3 kanban star target gear layers circle].freeze

      def initialize(root)
        @root = root
      end

      def lint
        files = Dir.glob(File.join(@root, "**", ".kiket", "issue_types.y{a}ml"))
        return [info_result("issue_types", nil, "No issue_types.yaml files found")] if files.empty?

        files.flat_map { |file| lint_file(file) }
      end

      private

      def lint_file(file)
        data = load_yaml(file)
        return [data] if data.is_a?(Result)

        results = []
        return [error_result("issue_types", file, "YAML document must be an object")] unless data.is_a?(Hash)

        model_version = data["model_version"]
        results << warning_result("issue_types", file, "Missing model_version") unless model_version

        issue_types = data["issue_types"]
        unless issue_types.is_a?(Array)
          return results + [error_result("issue_types", file, "Missing or invalid issue_types array")]
        end

        if issue_types.empty?
          return results + [error_result("issue_types", file, "issue_types array is empty")]
        end

        # Collect workflow files for cross-reference validation
        workflow_dir = File.join(File.dirname(file), "workflows")
        available_workflows = collect_workflow_ids(workflow_dir)

        issue_types.each_with_index do |type, idx|
          results.concat(lint_issue_type(file, type, idx, available_workflows))
        end

        results.empty? ? [success_result("issue_types", file, "Issue types lint passed")] : results
      end

      def lint_issue_type(file, type, idx, available_workflows)
        results = []
        prefix = "Issue type ##{idx + 1}"

        unless type.is_a?(Hash)
          return [error_result("issue_types", file, "#{prefix} must be an object")]
        end

        key = type["key"]
        if key.to_s.strip.empty?
          results << error_result("issue_types", file, "#{prefix} missing 'key'")
        elsif !key.to_s.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)
          results << error_result("issue_types", file,
                                  "#{prefix} key '#{key}' invalid; must start with letter, contain only alphanumeric/underscores")
        end

        color = type["color"]
        if color.present? && !VALID_COLORS.include?(color.to_s.downcase)
          results << warning_result("issue_types", file,
                                    "#{prefix} color '#{color}' unknown; will default to 'primary'")
        end

        icon = type["icon"]
        if icon.present? && !VALID_ICONS.include?(icon.to_s.downcase.gsub("_", "-"))
          results << warning_result("issue_types", file,
                                    "#{prefix} icon '#{icon}' unknown; will default to 'bookmark'")
        end

        # Validate workflow key if specified
        workflow_key = type["workflow"]
        if workflow_key.present?
          normalized_workflow_key = workflow_key.to_s.strip.downcase.gsub(/[^a-z0-9_-]/, "")

          unless workflow_key.to_s.match?(/\A[a-z][a-z0-9_-]*\z/)
            results << error_result("issue_types", file,
                                    "#{prefix} workflow '#{workflow_key}' invalid; must be lowercase alphanumeric with hyphens/underscores")
          end

          # Cross-reference: check if workflow exists
          if available_workflows.any? && !available_workflows.include?(normalized_workflow_key)
            results << warning_result("issue_types", file,
                                      "#{prefix} references workflow '#{workflow_key}' but no matching workflow found in #{File.basename(File.dirname(file))}/workflows/")
          end
        end

        results
      end

      def collect_workflow_ids(workflow_dir)
        return [] unless Dir.exist?(workflow_dir)

        workflow_ids = []
        Dir.glob(File.join(workflow_dir, "*.y{a}ml")).each do |workflow_file|
          data = load_yaml(workflow_file)
          next if data.is_a?(Result)
          next unless data.is_a?(Hash)

          workflow = data["workflow"]
          next unless workflow.is_a?(Hash)

          # Use workflow id or filename without extension
          workflow_id = workflow["id"]
          workflow_id ||= File.basename(workflow_file, ".*")
          workflow_ids << workflow_id.to_s.downcase if workflow_id.present?
        end
        workflow_ids
      end

      def load_yaml(file)
        YAML.safe_load_file(file, aliases: true) || {}
      rescue Psych::SyntaxError => e
        error_result("issue_types", file, "YAML syntax error: #{e.message}")
      end

      def error_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :error)
      end

      def warning_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :warning)
      end

      def info_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :info)
      end

      def success_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :success)
      end
    end

    class DashboardLinter
      def initialize(root)
        @root = root
      end

      def lint
        files = Dir.glob(File.join(@root, "**", ".kiket", "analytics", "dashboards", "**", "*.y{a}ml"))
        return [info_result("dashboards", nil, "No dashboard definitions found")] if files.empty?

        files.flat_map { |file| lint_file(file) }
      end

      private

      def lint_file(file)
        data = load_yaml(file)
        return [data] if data.is_a?(Result)

        dashboard = data["dashboard"]
        return [error_result("dashboards", file, "Missing dashboard root key")] unless dashboard.is_a?(Hash)

        results = []
        %w[id name].each do |field|
          if dashboard[field].to_s.strip.empty?
            results << error_result("dashboards", file,
                                    "dashboard.#{field} is required")
          end
        end

        widgets = dashboard["widgets"]
        if widgets.nil? || !widgets.is_a?(Array) || widgets.empty?
          results << error_result("dashboards", file, "Dashboard must declare at least one widget")
        else
          widgets.each do |widget|
            unless widget.is_a?(Hash)
              results << error_result("dashboards", file, "Widget entries must be objects")
              next
            end

            %w[id type title].each do |field|
              results << error_result("dashboards", file, "Widget missing #{field}") if widget[field].to_s.strip.empty?
            end

            unless widget["query"] || widget["query_config"]
              results << warning_result("dashboards", file,
                                        "Widget '#{widget["id"] || "unknown"}' missing query reference")
            end
          end
        end

        alerts = dashboard["alerts"]
        if alerts && !alerts.is_a?(Array)
          results << error_result("dashboards", file, "dashboard.alerts must be an array")
        end

        results.empty? ? [success_result("dashboards", file, "Dashboard lint passed")] : results
      end

      def load_yaml(file)
        YAML.safe_load_file(file, aliases: true) || {}
      rescue Psych::SyntaxError => e
        error_result("dashboards", file, "YAML syntax error: #{e.message}")
      end

      def error_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :error)
      end

      def warning_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :warning)
      end

      def info_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :info)
      end

      def success_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :success)
      end
    end

    class InboundEmailLinter
      VALID_SENDER_POLICIES = %w[open known_users known_domains].freeze
      VALID_PRIORITIES = %w[low medium high critical].freeze

      def initialize(root)
        @root = root
      end

      def lint
        files = Dir.glob(File.join(@root, "**", ".kiket", "inbound_email.y{a}ml"))
        return [info_result("inbound_email", nil, "No inbound_email.yaml files found")] if files.empty?

        files.flat_map { |file| lint_file(file) }
      end

      private

      def lint_file(file)
        data = load_yaml(file)
        return [data] if data.is_a?(Result)

        results = []
        return [error_result("inbound_email", file, "YAML document must be an object")] unless data.is_a?(Hash)

        inbound_email = data["inbound_email"]
        return results + [error_result("inbound_email", file, "Missing inbound_email root key")] unless inbound_email.is_a?(Hash)

        results << warning_result("inbound_email", file, "inbound_email.enabled is not set") if inbound_email["enabled"].nil?

        mappings = inbound_email["mappings"]
        if mappings.nil? || !mappings.is_a?(Array)
          results << error_result("inbound_email", file, "inbound_email.mappings must be an array")
        elsif mappings.empty?
          results << warning_result("inbound_email", file, "inbound_email.mappings is empty")
        else
          mappings.each_with_index do |mapping, idx|
            results.concat(lint_mapping(file, mapping, idx))
          end
        end

        results.empty? ? [success_result("inbound_email", file, "Inbound email config lint passed")] : results
      end

      def lint_mapping(file, mapping, idx)
        results = []
        prefix = "Mapping ##{idx + 1}"

        unless mapping.is_a?(Hash)
          return [error_result("inbound_email", file, "#{prefix} must be an object")]
        end

        email_address = mapping["email_address"]
        if email_address.to_s.strip.empty?
          results << error_result("inbound_email", file, "#{prefix} missing email_address")
        end

        sender_policy = mapping["sender_policy"]
        if sender_policy.present? && !VALID_SENDER_POLICIES.include?(sender_policy)
          results << error_result("inbound_email", file,
                                  "#{prefix} has invalid sender_policy '#{sender_policy}'; must be one of: #{VALID_SENDER_POLICIES.join(', ')}")
        end

        issue_defaults = mapping["issue_defaults"]
        if issue_defaults.is_a?(Hash)
          priority = issue_defaults["priority"]
          if priority.present? && !VALID_PRIORITIES.include?(priority)
            results << error_result("inbound_email", file,
                                    "#{prefix} has invalid priority '#{priority}'; must be one of: #{VALID_PRIORITIES.join(', ')}")
          end
        end

        if mapping["auto_reply"] && mapping["auto_reply_template"].to_s.strip.empty?
          results << warning_result("inbound_email", file, "#{prefix} has auto_reply enabled but no auto_reply_template")
        end

        results
      end

      def load_yaml(file)
        YAML.safe_load_file(file, aliases: true) || {}
      rescue Psych::SyntaxError => e
        error_result("inbound_email", file, "YAML syntax error: #{e.message}")
      end

      def error_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :error)
      end

      def warning_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :warning)
      end

      def info_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :info)
      end

      def success_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :success)
      end
    end

    class DbtLinter
      def initialize(root, project_path:, run_cli: true)
        @root = root
        @project_path = project_path && File.expand_path(project_path)
        @run_cli = run_cli
      end

      def lint
        results = []
        exposure_files = Dir.glob(File.join(@root, "**", "analytics", "dbt", "**", "*.y{a}ml"))
        exposure_files.each do |file|
          next if File.basename(file) == "dbt_project.yml"

          results.concat(lint_exposure_file(file))
        end

        if @project_path && @run_cli
          results.concat(run_dbt_parse)
        elsif @run_cli && @project_path.nil?
          results << info_result("dbt", nil, "Skipped dbt CLI run (no analytics/dbt project found)")
        end

        results.empty? ? [success_result("dbt", @project_path, "dbt lint passed")] : results
      end

      private

      def lint_exposure_file(file)
        data = load_yaml(file)
        return [data] if data.is_a?(Result)

        results = []
        exposures = data["exposures"]
        return [] unless exposures # ignore non-exposure files

        return [error_result("dbt", file, "exposures must be an array")] unless exposures.is_a?(Array)

        exposures.each do |exposure|
          unless exposure.is_a?(Hash)
            results << error_result("dbt", file, "Exposure entries must be objects")
            next
          end

          %w[name type maturity].each do |field|
            results << error_result("dbt", file, "Exposure missing #{field}") if exposure[field].to_s.strip.empty?
          end

          if exposure["depends_on"].nil? || exposure["depends_on"].empty?
            results << warning_result("dbt", file,
                                      "Exposure '#{exposure["name"] || "unknown"}' has no depends_on entries")
          end
        end

        results
      end

      def run_dbt_parse
        unless dbt_available?
          return [info_result("dbt", @project_path,
                              "dbt command not available; skipping parse run")]
        end
        unless Dir.exist?(@project_path)
          return [error_result("dbt", @project_path,
                               "dbt project path #{@project_path} not found")]
        end

        Dir.chdir(@project_path) do
          cmd = %w[dbt parse]
          cmd += ["--project-dir", @project_path]
          profiles_dir = File.join(@project_path, "profiles")
          cmd += ["--profiles-dir", profiles_dir] if Dir.exist?(profiles_dir)

          stdout, stderr, status = Open3.capture3(*cmd)
          unless status.success?
            return [error_result("dbt", @project_path, "dbt parse failed", stdout: stdout, stderr: stderr)]
          end
        end

        [success_result("dbt", @project_path, "dbt parse succeeded")]
      rescue StandardError => e
        [error_result("dbt", @project_path, "dbt parse error: #{e.message}")]
      end

      def dbt_available?
        system("which dbt > /dev/null 2>&1")
      end

      def load_yaml(file)
        YAML.safe_load_file(file, aliases: true)
      rescue Psych::SyntaxError => e
        error_result("dbt", file, "YAML syntax error: #{e.message}")
      end

      def error_result(category, file, message, stdout: nil, stderr: nil)
        Result.new(
          category: category,
          file: file,
          message: message,
          severity: :error,
          metadata: { stdout: stdout, stderr: stderr }.compact
        )
      end

      def warning_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :warning)
      end

      def info_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :info)
      end

      def success_result(category, file, message)
        Result.new(category: category, file: file, message: message, severity: :success)
      end
    end
  end
end
