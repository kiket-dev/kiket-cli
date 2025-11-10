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
      def initialize(root:, include_workflows: true, include_dashboards: true, include_dbt: true, dbt_project_path: nil,
                     run_dbt_cli: true)
        @root = File.expand_path(root)
        @include_workflows = include_workflows
        @include_dashboards = include_dashboards
        @include_dbt = include_dbt
        @dbt_project_path = dbt_project_path || default_dbt_project
        @run_dbt_cli = run_dbt_cli
      end

      def run
        results = []
        results.concat(WorkflowLinter.new(@root).lint) if @include_workflows
        results.concat(DashboardLinter.new(@root).lint) if @include_dashboards
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

        results = []

        unless data.is_a?(Hash)
          return [error_result("workflows", file, "YAML document must be an object")]
        end

        model_version = data["model_version"] || data.dig("workflow", "model_version")
        results << error_result("workflows", file, "Missing model_version") unless model_version

        workflow = data["workflow"] || {}
        name = workflow["name"]
        results << error_result("workflows", file, "Missing workflow.name") if name.to_s.strip.empty?

        states = data["states"] || workflow["states"]
        if states.nil? || !states.is_a?(Hash) || states.empty?
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
            results << error_result("workflows", file, "Transition ##{idx + 1} missing 'from'") if from.to_s.strip.empty?
            results << error_result("workflows", file, "Transition ##{idx + 1} missing 'to'") if to.to_s.strip.empty?
          end
        end

        results.empty? ? [success_result("workflows", file, "Workflow lint passed")] : results
      end

      def load_yaml(file)
        YAML.safe_load(File.read(file), aliases: true) || {}
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
        unless dashboard.is_a?(Hash)
          return [error_result("dashboards", file, "Missing dashboard root key")]
        end

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

            unless widget["query"] || widget["query_config"]
              results << warning_result("dashboards", file, "Widget '#{widget["id"] || "unknown"}' missing query reference")
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
        YAML.safe_load(File.read(file), aliases: true) || {}
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

        unless exposures.is_a?(Array)
          return [error_result("dbt", file, "exposures must be an array")]
        end

        exposures.each do |exposure|
          unless exposure.is_a?(Hash)
            results << error_result("dbt", file, "Exposure entries must be objects")
            next
          end

          %w[name type maturity].each do |field|
            if exposure[field].to_s.strip.empty?
              results << error_result("dbt", file, "Exposure missing #{field}")
            end
          end

          if exposure["depends_on"].nil? || exposure["depends_on"].empty?
            results << warning_result("dbt", file, "Exposure '#{exposure["name"] || "unknown"}' has no depends_on entries")
          end
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
        YAML.safe_load(File.read(file), aliases: true)
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
