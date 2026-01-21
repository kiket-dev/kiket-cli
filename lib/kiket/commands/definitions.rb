# frozen_string_literal: true

require "pathname"
require_relative "base"
require_relative "../../kiket/definition_testing"

module Kiket
  module Commands
    class Definitions < Base
      desc "lint [PATH]", "Lint definition assets (projects, workflows, issue_types, dashboards, inbound_email, dbt)"
      option :projects, type: :boolean, default: true, desc: "Include project.yaml linting"
      option :workflows, type: :boolean, default: true, desc: "Include workflow linting"
      option :issue_types, type: :boolean, default: true, desc: "Include issue_types.yaml linting"
      option :dashboards, type: :boolean, default: true, desc: "Include dashboard linting"
      option :inbound_email, type: :boolean, default: true, desc: "Include inbound_email.yaml linting"
      option :dbt, type: :boolean, default: true, desc: "Include dbt linting"
      option :dbt_project, type: :string, desc: "Override analytics/dbt project path"
      option :skip_dbt_cli, type: :boolean, default: false, desc: "Skip running dbt parse"
      option :fail_fast, type: :boolean, default: false, desc: "Exit on first error"
      def lint(path = ".")
        harness = DefinitionTesting::Harness.new(
          root: path,
          include_projects: options[:projects],
          include_workflows: options[:workflows],
          include_issue_types: options[:issue_types],
          include_dashboards: options[:dashboards],
          include_inbound_email: options[:inbound_email],
          include_dbt: options[:dbt],
          dbt_project_path: options[:dbt_project],
          run_dbt_cli: !options[:skip_dbt_cli]
        )

        results = []
        harness.run.each do |result|
          results << result
          break if options[:fail_fast] && result.severity == :error
        end

        errors = results.select { |r| r.severity == :error }
        warnings = results.select { |r| r.severity == :warning }

        if output_format == "json"
          output_json(results.map(&:to_h))
        elsif output_format == "csv"
          output_csv(
            results.map(&:to_h),
            headers: %i[category severity file message]
          )
        else
          render_human(results)
        end

        if errors.any?
          exit 1
        else
          success "Definition lint completed with #{warnings.size} warning(s)"
        end
      rescue StandardError => e
        handle_error(e)
      end

      private

      def render_human(results)
        return info "No results" if results.empty?

        longest_category = results.map { |r| r.category.to_s.length }.max || 0
        results.each do |result|
          colorized = case result.severity
                      when :error then pastel.red("✗")
                      when :warning then pastel.yellow("⚠")
                      when :success then pastel.green("✓")
                      else pastel.dim("·")
                      end
          file_info = result.file ? " (#{relative_path(result.file)})" : ""
          puts format("%s %-#{longest_category}s %s%s",
                                    colorized,
                                    result.category,
                                    result.message,
                                    file_info)
          next unless result.metadata&.any?

          result.metadata.each do |key, value|
            next if value.to_s.strip.empty?

            puts pastel.dim("    #{key}: #{truncate(value)}")
          end
        end
      end

      def relative_path(path)
        return path unless path

        Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(Dir.pwd)).to_s
      rescue ArgumentError
        path
      end

      def truncate(value, limit = 160)
        string = value.to_s
        return string if string.length <= limit

        "#{string[0, limit]}…"
      end
    end
  end
end
