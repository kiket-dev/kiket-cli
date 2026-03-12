# frozen_string_literal: true

require "yaml"
require "json"
require "open3"
require "time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"

module Kiket
  module DefinitionTesting
    Result = Struct.new(:category, :file, :message, :severity, :metadata) do
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

    class BaseLinter
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

      def load_yaml(file)
        YAML.safe_load_file(file, aliases: true) || {}
      rescue Psych::SyntaxError => e
        error_result("yaml", file, "YAML syntax error: #{e.message}")
      end
    end

    class Harness
      def initialize(root:, include_workflows: true, include_dashboards: true, include_dbt: true, include_projects: true,
                     include_inbound_email: true, include_issue_types: true, include_agents: true, include_intakes: true,
                     dbt_project_path: nil, run_dbt_cli: true)
        @root = File.expand_path(root)
        @include_workflows = include_workflows
        @include_dashboards = include_dashboards
        @include_dbt = include_dbt
        @include_projects = include_projects
        @include_inbound_email = include_inbound_email
        @include_issue_types = include_issue_types
        @include_agents = include_agents
        @include_intakes = include_intakes
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
        results.concat(AgentLinter.new(@root).lint) if @include_agents
        results.concat(IntakeLinter.new(@root).lint) if @include_intakes
        results.concat(DbtLinter.new(@root, project_path: @dbt_project_path, run_cli: @run_dbt_cli).lint) if @include_dbt
        results
      end

      private

      def default_dbt_project
        project_candidate = File.join(@root, "analytics", "dbt")
        return project_candidate if Dir.exist?(project_candidate)

        repo_candidate = File.expand_path(File.join(__dir__, "..", "..", "analytics", "dbt"))
        Dir.exist?(repo_candidate) ? repo_candidate : nil
      end
    end

    class ProjectLinter < BaseLinter
      SUPPORTED_ROOT_KEYS = %w[model_version project].freeze
      SUPPORTED_PROJECT_KEYS = %w[key name version description team settings].freeze
      SUPPORTED_TEAM_KEYS = %w[roles].freeze
      PROJECT_KEY_PATTERN = /\A[A-Z][A-Z0-9]*\z/

      def initialize(root)
        super()
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
        return [data] if data.is_a?(Result)

        results = []

        return [error_result("projects", file, "YAML document must be an object")] unless data.is_a?(Hash)

        check_unsupported_keys(results, data, SUPPORTED_ROOT_KEYS, "root", file)

        model_version = data["model_version"]
        results << error_result("projects", file, "Missing model_version") unless model_version

        project = data["project"]
        return results + [error_result("projects", file, "Missing project root key")] unless project.is_a?(Hash)

        check_unsupported_keys(results, project, SUPPORTED_PROJECT_KEYS, "project", file)

        # Check for deprecated 'id' field
        results << error_result("projects", file, "project.id is deprecated; use project.key instead (must be uppercase alphanumeric, e.g., 'SUPPORT', 'ENGINEERING')") if project.key?("id")

        # Require 'key' field
        key = project["key"]
        if key.to_s.strip.empty?
          results << error_result("projects", file, "project.key is required")
        elsif !key.to_s.match?(PROJECT_KEY_PATTERN)
          results << error_result("projects", file, "project.key '#{key}' invalid; must be uppercase alphanumeric (e.g., 'SUPPORT', 'ENGINEERING')")
        end

        name = project["name"]
        results << error_result("projects", file, "project.name is required") if name.to_s.strip.empty?

        validate_team_roles(results, project, file)

        results.empty? ? [success_result("projects", file, "Project lint passed")] : results
      end

      def validate_team_roles(results, project, file)
        team = project["team"]
        if team.nil? || !team.is_a?(Hash)
          results << warning_result("projects", file, "project.team section is not defined; consider adding team roles")
          return
        end

        check_unsupported_keys(results, team, SUPPORTED_TEAM_KEYS, "project.team", file)

        roles = team["roles"]
        if roles.nil? || !roles.is_a?(Array) || roles.empty?
          results << warning_result("projects", file, "project.team.roles is not defined; role dropdowns will fall back to 'member'")
          return
        end

        roles.each_with_index do |role, idx|
          unless role.is_a?(Hash)
            results << error_result("projects", file, "Role ##{idx + 1} must be a mapping with 'name' field")
            next
          end

          name = role["name"]
          if name.to_s.strip.empty?
            results << error_result("projects", file, "Role ##{idx + 1} missing 'name' field")
          elsif !name.to_s.match?(/\A[a-zA-Z][a-zA-Z0-9_-]{0,49}\z/)
            results << error_result("projects", file, "Role '#{name}' has invalid format; must start with letter, contain only letters/numbers/underscores/hyphens, max 50 chars")
          end
        end
      end

      def check_unsupported_keys(results, data, supported_keys, path, file)
        return unless data.is_a?(Hash)

        unsupported = data.keys - supported_keys
        unsupported.each do |key|
          results << warning_result("projects", file, "Unsupported key '#{path}.#{key}' found; may be ignored")
        end
      end
    end

    class WorkflowLinter < BaseLinter
      SUPPORTED_ROOT_KEYS = %w[model_version workflow states transitions].freeze
      SUPPORTED_WORKFLOW_KEYS = %w[id name model_version description initial_state].freeze

      def initialize(root)
        super()
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
        return [data] if data.is_a?(Result)

        return [info_result("workflows", file, "Skipped automation recipe definition")] if data.is_a?(Hash) && data.key?("recipe")

        results = []

        return [error_result("workflows", file, "YAML document must be an object")] unless data.is_a?(Hash)

        model_version = data["model_version"] || data.dig("workflow", "model_version")
        results << error_result("workflows", file, "Missing model_version") unless model_version

        workflow = data["workflow"] || {}
        name = workflow["name"]
        results << error_result("workflows", file, "Missing workflow.name") if name.to_s.strip.empty?

        workflow_id = workflow["id"]
        if workflow_id.to_s.strip.empty?
          results << warning_result("workflows", file, "Missing workflow.id; recommended for multi-workflow support")
        elsif !workflow_id.to_s.match?(/\A[a-z][a-z0-9_-]*\z/)
          results << error_result("workflows", file, "workflow.id '#{workflow_id}' invalid; must be lowercase alphanumeric with hyphens/underscores")
        end

        states = data["states"] || workflow["states"]
        validate_states(results, states, file)

        transitions = data["transitions"] || workflow["transitions"] || []
        validate_transitions(results, transitions, file)

        results.empty? ? [success_result("workflows", file, "Workflow lint passed")] : results
      end

      def validate_states(results, states, file)
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
      end

      def validate_transitions(results, transitions, file)
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
            results << error_result("workflows", file, "Transition ##{idx + 1} missing 'from'") if from.to_s.strip.empty?
            results << error_result("workflows", file, "Transition ##{idx + 1} missing 'to'") if to.to_s.strip.empty?
          end
        end
      end
    end

    class IssueTypesLinter < BaseLinter
      VALID_COLORS = %w[primary secondary success danger warning info light dark purple].freeze
      ICON_PATTERN = /\A[a-z][a-z0-9-]*\z/

      def initialize(root)
        super()
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
        return results + [error_result("issue_types", file, "Missing or invalid issue_types array")] unless issue_types.is_a?(Array)

        return results + [error_result("issue_types", file, "issue_types array is empty")] if issue_types.empty?

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

        return [error_result("issue_types", file, "#{prefix} must be an object")] unless type.is_a?(Hash)

        key = type["key"]
        if key.to_s.strip.empty?
          results << error_result("issue_types", file, "#{prefix} missing 'key'")
        elsif !key.to_s.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)
          results << error_result("issue_types", file, "#{prefix} key '#{key}' invalid; must start with letter, contain only alphanumeric/underscores")
        end

        color = type["color"]
        results << warning_result("issue_types", file, "#{prefix} color '#{color}' unknown; will default to 'primary'") if color.present? && VALID_COLORS.exclude?(color.to_s.downcase)

        icon = type["icon"]
        if icon.present?
          normalized_icon = icon.to_s.downcase.tr("_", "-")
          results << warning_result("issue_types", file, "#{prefix} icon '#{icon}' has invalid format; must be lowercase alphanumeric with hyphens") unless normalized_icon.match?(ICON_PATTERN)
        end

        workflow_key = type["workflow"]
        if workflow_key.present?
          normalized_workflow_key = workflow_key.to_s.strip.downcase.gsub(/[^a-z0-9_-]/, "")

          unless workflow_key.to_s.match?(/\A[a-z][a-z0-9_-]*\z/)
            results << error_result("issue_types", file, "#{prefix} workflow '#{workflow_key}' invalid; must be lowercase alphanumeric with hyphens/underscores")
          end

          if available_workflows.any? && available_workflows.exclude?(normalized_workflow_key)
            results << warning_result("issue_types", file, "#{prefix} references workflow '#{workflow_key}' but no matching workflow found in #{File.basename(File.dirname(file))}/workflows/")
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

          workflow_id = workflow["id"]
          workflow_id ||= File.basename(workflow_file, ".*")
          workflow_ids << workflow_id.to_s.downcase if workflow_id.present?
        end
        workflow_ids
      end
    end

    class DashboardLinter < BaseLinter
      SUPPORTED_DASHBOARD_KEYS = %w[id name description widgets alerts].freeze

      def initialize(root)
        super()
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
          results << error_result("dashboards", file, "dashboard.#{field} is required") if dashboard[field].to_s.strip.empty?
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

            results << warning_result("dashboards", file, "Widget '#{widget["id"] || "unknown"}' missing query reference") unless widget["query"] || widget["query_config"]
          end
        end

        alerts = dashboard["alerts"]
        results << error_result("dashboards", file, "dashboard.alerts must be an array") if alerts && !alerts.is_a?(Array)

        results.empty? ? [success_result("dashboards", file, "Dashboard lint passed")] : results
      end
    end

    class InboundEmailLinter < BaseLinter
      VALID_SENDER_POLICIES = %w[open known_users known_domains].freeze
      VALID_PRIORITIES = %w[low medium high critical].freeze

      SUPPORTED_MAPPING_KEYS = %w[email_address sender_policy issue_defaults auto_reply auto_reply_template].freeze

      def initialize(root)
        super()
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

        return [error_result("inbound_email", file, "#{prefix} must be an object")] unless mapping.is_a?(Hash)

        email_address = mapping["email_address"]
        results << error_result("inbound_email", file, "#{prefix} missing email_address") if email_address.to_s.strip.empty?

        sender_policy = mapping["sender_policy"]
        if sender_policy.present? && VALID_SENDER_POLICIES.exclude?(sender_policy)
          results << error_result("inbound_email", file, "#{prefix} has invalid sender_policy '#{sender_policy}'; must be one of: #{VALID_SENDER_POLICIES.join(", ")}")
        end

        issue_defaults = mapping["issue_defaults"]
        if issue_defaults.is_a?(Hash)
          priority = issue_defaults["priority"]
          if priority.present? && VALID_PRIORITIES.exclude?(priority)
            results << error_result("inbound_email", file, "#{prefix} has invalid priority '#{priority}'; must be one of: #{VALID_PRIORITIES.join(", ")}")
          end
        end

        results << warning_result("inbound_email", file, "#{prefix} has auto_reply enabled but no auto_reply_template") if mapping["auto_reply"] && mapping["auto_reply_template"].to_s.strip.empty?

        results
      end
    end

    class AgentLinter < BaseLinter
      SUPPORTED_AGENT_KEYS = %w[id name version description prompts capabilities inputs outputs tools].freeze

      def initialize(root)
        super()
        @root = root
      end

      def lint
        files = Dir.glob(File.join(@root, "**", ".kiket", "agents", "*.y{a}ml"))
        return [info_result("agents", nil, "No agent files found")] if files.empty?

        files.flat_map { |file| lint_file(file) }
      end

      private

      def lint_file(file)
        data = load_yaml(file)
        return [data] if data.is_a?(Result)

        results = []
        return [error_result("agents", file, "YAML document must be an object")] unless data.is_a?(Hash)

        model_version = data["model_version"]
        results << warning_result("agents", file, "Missing model_version") unless model_version

        agent = data["agent"]

        # Check for deprecated top-level agent fields (not wrapped in agent: block)
        deprecated_top_level_keys = %w[id name version prompt capabilities inputs outputs tools]
        deprecated_top_level_keys.each do |key|
          results << error_result("agents", file, "Agent definition has '#{key}' at top level; wrap all agent fields in 'agent:' block") if data.key?(key) && !agent.is_a?(Hash)
        end

        # Check for deprecated 'prompt' field inside agent block
        results << error_result("agents", file, "agent.prompt is deprecated; use agent.prompts (array with role and content)") if agent.is_a?(Hash) && agent.key?("prompt")

        return results + [error_result("agents", file, "Missing agent root key; wrap agent definition in 'agent:' block")] unless agent.is_a?(Hash)

        check_unsupported_keys(results, agent, SUPPORTED_AGENT_KEYS, "agent", file)

        id = agent["id"]
        if id.to_s.strip.empty?
          results << error_result("agents", file, "agent.id is required")
        elsif !id.to_s.match?(/\A[a-z][a-z0-9._]*\z/)
          results << error_result("agents", file, "agent.id '#{id}' invalid; must be lowercase alphanumeric with dots/underscores (e.g., 'ai.support.categorize')")
        end

        name = agent["name"]
        results << error_result("agents", file, "agent.name is required") if name.to_s.strip.empty?

        prompts = agent["prompts"]
        if prompts.nil?
          results << warning_result("agents", file, "agent.prompts is not defined")
        elsif !prompts.is_a?(Array)
          results << error_result("agents", file, "agent.prompts must be an array")
        elsif prompts.empty?
          results << warning_result("agents", file, "agent.prompts is empty")
        else
          prompts.each_with_index do |prompt, idx|
            unless prompt.is_a?(Hash)
              results << error_result("agents", file, "agent.prompts[#{idx}] must be an object with 'role' and 'content'")
              next
            end

            role = prompt["role"]
            content = prompt["content"]
            results << error_result("agents", file, "agent.prompts[#{idx}] missing 'role'") if role.to_s.strip.empty?
            results << error_result("agents", file, "agent.prompts[#{idx}] missing 'content'") if content.to_s.strip.empty?
          end
        end

        capabilities = agent["capabilities"]
        results << error_result("agents", file, "agent.capabilities must be an array") if capabilities && !capabilities.is_a?(Array)

        inputs = agent["inputs"]
        results << error_result("agents", file, "agent.inputs must be an array") if inputs && !inputs.is_a?(Array)

        outputs = agent["outputs"]
        results << error_result("agents", file, "agent.outputs must be an array") if outputs && !outputs.is_a?(Array)

        tools = agent["tools"]
        results << error_result("agents", file, "agent.tools must be an array") if tools && !tools.is_a?(Array)

        results.empty? ? [success_result("agents", file, "Agent lint passed")] : results
      end

      def check_unsupported_keys(results, data, supported_keys, path, file)
        return unless data.is_a?(Hash)

        unsupported = data.keys - supported_keys
        unsupported.each do |key|
          results << warning_result("agents", file, "Unsupported key '#{path}.#{key}' found; may be ignored")
        end
      end
    end

    class IntakeLinter < BaseLinter
      SUPPORTED_SETTINGS_KEYS = %w[public captcha_enabled rate_limit requires_approval default_issue_type default_priority confirmation_message].freeze
      SUPPORTED_FIELD_KEYS = %w[key type label required placeholder default options maps_to helper_text min max step accept multiple allowed_types max_size_mb max_files description validation].freeze
      SUPPORTED_OPTION_KEYS = %w[value label description values].freeze

      def initialize(root)
        super()
        @root = root
      end

      def lint
        files = Dir.glob(File.join(@root, "**", ".kiket", "intakes", "*.y{a}ml"))
        return [info_result("intakes", nil, "No intake files found")] if files.empty?

        files.flat_map { |file| lint_file(file) }
      end

      private

      def lint_file(file)
        data = load_yaml(file)
        return [data] if data.is_a?(Result)

        results = []
        return [error_result("intakes", file, "YAML document must be an object")] unless data.is_a?(Hash)

        model_version = data["model_version"]
        results << warning_result("intakes", file, "Missing model_version") unless model_version

        # Check for deprecated 'intake' key
        results << error_result("intakes", file, "Root key 'intake' is deprecated; use 'intake_form' instead") if data.key?("intake")

        intake_form = data["intake_form"]
        return results + [error_result("intakes", file, "Missing intake_form root key")] unless intake_form.is_a?(Hash)

        key = intake_form["key"] || intake_form["id"]
        if key.to_s.strip.empty?
          results << error_result("intakes", file, "intake_form.key is required")
        elsif !key.to_s.match?(/\A[a-z][a-z0-9_-]*\z/)
          results << error_result("intakes", file, "intake_form.key '#{key}' invalid; must be lowercase alphanumeric with hyphens/underscores")
        end

        name = intake_form["name"]
        results << error_result("intakes", file, "intake_form.name is required") if name.to_s.strip.empty?

        settings = intake_form["settings"]
        validate_settings(results, settings, file) if settings

        fields = intake_form["fields"]
        if fields.nil?
          results << warning_result("intakes", file, "intake_form.fields is not defined")
        elsif !fields.is_a?(Array)
          results << error_result("intakes", file, "intake_form.fields must be an array")
        elsif fields.empty?
          results << warning_result("intakes", file, "intake_form.fields is empty")
        else
          fields.each_with_index do |field, idx|
            results.concat(lint_field(file, field, idx))
          end
        end

        results.empty? ? [success_result("intakes", file, "Intake form lint passed")] : results
      end

      def validate_settings(results, settings, file)
        return unless settings.is_a?(Hash)

        settings.each_key do |key|
          next if SUPPORTED_SETTINGS_KEYS.include?(key.to_s)

          results << warning_result("intakes", file, "Unsupported settings key '#{key}'")
        end
      end

      def lint_field(file, field, idx)
        results = []
        prefix = "Field ##{idx + 1}"

        return [error_result("intakes", file, "#{prefix} must be an object")] unless field.is_a?(Hash)

        key = field["key"]
        if key.to_s.strip.empty?
          results << error_result("intakes", file, "#{prefix} missing 'key'")
        elsif !key.to_s.match?(/\A[a-z][a-z0-9_]*\z/)
          results << error_result("intakes", file, "#{prefix} key '#{key}' invalid; must be lowercase alphanumeric with underscores")
        end

        type = field["type"]
        valid_types = %w[string text markdown email url phone date enum multi_enum file number boolean divider heading]
        if type.to_s.strip.empty?
          results << error_result("intakes", file, "#{prefix} missing 'type'")
        elsif valid_types.exclude?(type.to_s.downcase)
          results << warning_result("intakes", file, "#{prefix} type '#{type}' may not be supported")
        end

        label = field["label"]
        display_only_types = %w[divider heading markdown]
        results << error_result("intakes", file, "#{prefix} missing 'label'") if label.to_s.strip.empty? && display_only_types.exclude?(type.to_s.downcase)

        options = field["options"]
        if options
          case options
          when Hash
            if options["values"]
              values = options["values"]
              results << error_result("intakes", file, "#{prefix} options.values must be an array") unless values.is_a?(Array)
            end
          when Array
            options.each_with_index do |opt, opt_idx|
              next unless opt.is_a?(Hash)

              results << error_result("intakes", file, "#{prefix} option ##{opt_idx + 1} missing 'value'") if opt["value"].to_s.strip.empty?
            end
          else
            results << error_result("intakes", file, "#{prefix} options must be an array or object with 'values' key")
          end
        end

        results
      end
    end

    class DbtLinter < BaseLinter
      def initialize(root, project_path:, run_cli: true)
        super()
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
        return [] unless exposures

        return [error_result("dbt", file, "exposures must be an array")] unless exposures.is_a?(Array)

        exposures.each do |exposure|
          unless exposure.is_a?(Hash)
            results << error_result("dbt", file, "Exposure entries must be objects")
            next
          end

          %w[name type maturity].each do |field|
            results << error_result("dbt", file, "Exposure missing #{field}") if exposure[field].to_s.strip.empty?
          end

          results << warning_result("dbt", file, "Exposure '#{exposure["name"] || "unknown"}' has no depends_on entries") if exposure["depends_on"].blank?
        end

        results
      end

      def run_dbt_parse
        return [info_result("dbt", @project_path, "dbt command not available; skipping parse run")] unless dbt_available?
        return [error_result("dbt", @project_path, "dbt project path #{@project_path} not found")] unless Dir.exist?(@project_path)

        Dir.chdir(@project_path) do
          cmd = %w[dbt parse]
          cmd += ["--project-dir", @project_path]
          profiles_dir = File.join(@project_path, "profiles")
          cmd += ["--profiles-dir", profiles_dir] if Dir.exist?(profiles_dir)

          stdout, stderr, status = Open3.capture3(*cmd)
          return [error_result("dbt", @project_path, "dbt parse failed", stdout: stdout, stderr: stderr)] unless status.success?
        end

        [success_result("dbt", @project_path, "dbt parse succeeded")]
      rescue StandardError => e
        [error_result("dbt", @project_path, "dbt parse error: #{e.message}")]
      end

      def dbt_available?
        system("which dbt > /dev/null 2>&1")
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
    end
  end
end
