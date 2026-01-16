# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Agents < Base
      desc "list PROJECT_ID", "List agent definitions synced into a project"
      option :capability, type: :string, desc: "Filter by capability tag"
      def list(project_id)
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        response = client.get("/api/v1/projects/#{project_id}/agents", params: { organization: org })
        entries = response.fetch("agents", [])
        if options[:capability]
          entries = entries.select { |entry| Array(entry["capabilities"]).include?(options[:capability]) }
        end

        if output_format == "human"
          if entries.empty?
            warning "No agents found for project #{response.dig("project", "name") || project_id}."
            return
          end

          rows = entries.map do |entry|
            {
              id: entry["id"],
              name: entry["name"],
              capabilities: Array(entry["capabilities"]).join(", "),
              inputs: format_endpoints(entry["inputs"]),
              outputs: format_endpoints(entry["outputs"])
            }
          end

          output_data(rows, headers: %i[id name capabilities inputs outputs])
        else
          output_data(entries, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "execute AGENT_ID", "Execute an agent with the specified input"
      option :project, type: :string, required: true, desc: "Project ID or slug"
      option :input, type: :string, desc: "JSON input payload"
      option :input_file, type: :string, desc: "Path to JSON file with input payload"
      option :stream, type: :boolean, default: false, desc: "Stream output as it arrives"
      def execute(agent_id)
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        input = parse_input
        project_id = options[:project]

        if options[:stream]
          run_streaming(org, project_id, agent_id, input)
        else
          run_sync(org, project_id, agent_id, input)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "quota", "Show AI agent quota and usage for the organization"
      def quota
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        response = client.get("/api/v1/ai/quota", params: { organization: org })

        if output_format == "human"
          puts pastel.bold("AI Agent Quota")
          puts ""

          quota_data = response.fetch("quota", {})
          usage_data = response.fetch("usage", {})

          rows = quota_data.map do |feature, limit|
            used = usage_data[feature] || 0
            remaining = limit == "unlimited" ? "unlimited" : [limit.to_i - used, 0].max
            status = if limit == "unlimited"
                       pastel.green("OK")
                     elsif used >= limit.to_i
                       pastel.red("EXCEEDED")
                     elsif used >= limit.to_i * 0.8
                       pastel.yellow("APPROACHING")
                     else
                       pastel.green("OK")
                     end

            {
              feature: feature,
              limit: limit,
              used: used,
              remaining: remaining,
              status: status
            }
          end

          output_data(rows, headers: %i[feature limit used remaining status])

          puts ""
          puts "Plan: #{response.dig("plan", "name") || "Unknown"}"
          puts "Billing period: #{response["billing_period"] || "Monthly"}"
        else
          output_data(response, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "catalog", "List all available agents in the registry"
      option :category, type: :string, desc: "Filter by category"
      def catalog
        ensure_authenticated!
        org = organization

        response = client.get("/api/v1/ai/agents", params: { organization: org }.compact)
        entries = response.fetch("agents", [])

        entries = entries.select { |e| e.dig("metadata", "category") == options[:category] } if options[:category]

        if output_format == "human"
          if entries.empty?
            warning "No agents found in the catalog."
            return
          end

          rows = entries.map do |entry|
            {
              id: entry["id"],
              name: entry["name"],
              version: entry["version"],
              capabilities: Array(entry["capabilities"]).join(", "),
              category: entry.dig("metadata", "category") || "-"
            }
          end

          output_data(rows, headers: %i[id name version capabilities category])
        else
          output_data(entries, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "actions", "List available AI actions for a project"
      option :project, type: :string, required: true, desc: "Project ID or slug"
      option :category, type: :string, desc: "Filter by category"
      option :capability, type: :string, desc: "Filter by capability"
      def actions
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        params = { organization: org, project_id: options[:project] }
        params[:category] = options[:category] if options[:category]
        params[:capability] = options[:capability] if options[:capability]

        response = client.get("/api/v1/ai_actions", params: params)
        entries = response.fetch("actions", [])

        if output_format == "human"
          if entries.empty?
            warning "No AI actions found for this project."
            return
          end

          rows = entries.map do |entry|
            {
              id: entry["id"],
              name: entry["name"],
              description: truncate_text(entry["description"], 40),
              category: entry["category"] || "-",
              cost_tier: entry["cost_tier"] || "-"
            }
          end

          output_data(rows, headers: %i[id name description category cost_tier])

          puts ""
          puts "Categories: #{response.fetch("categories", []).join(", ")}"
          puts "Capabilities: #{response.fetch("capabilities", []).join(", ")}"
        else
          output_data(response, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "execute AGENT_ID", "Execute an AI action"
      option :project, type: :string, required: true, desc: "Project ID or slug"
      option :input, type: :string, desc: "JSON input payload"
      option :input_file, type: :string, desc: "Path to JSON file with input payload"
      option :resource_type, type: :string, desc: "Resource type (e.g., Issue)"
      option :resource_id, type: :string, desc: "Resource ID"
      option :trigger_source, type: :string, default: "cli", desc: "Trigger source identifier"
      def execute(agent_id)
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        input = parse_input
        project_id = options[:project]

        spinner = TTY::Spinner.new("[:spinner] Executing AI action #{agent_id}...", format: :dots)
        spinner.auto_spin

        body = {
          project_id: project_id,
          input: input,
          trigger_source: options[:trigger_source]
        }
        body[:resource_type] = options[:resource_type] if options[:resource_type]
        body[:resource_id] = options[:resource_id] if options[:resource_id]

        response = client.post(
          "/api/v1/ai_actions/#{agent_id}/execute",
          body,
          params: { organization: org }
        )

        if response["status"] == "failed"
          spinner.error("Failed!")
          error response["error"] || "Execution failed"
          exit 1
        else
          spinner.success("Done!")
        end

        if output_format == "human"
          puts ""
          puts pastel.bold("Execution Result:")
          puts "  Status: #{colorize_status(response["status"])}"
          puts "  Execution ID: #{response["execution_id"]}"

          if response["output"]
            puts ""
            puts pastel.bold("Output:")
            output_text = response["output"].is_a?(String) ? response["output"] : JSON.pretty_generate(response["output"])
            puts output_text
          end

          if response["metadata"]
            puts ""
            puts "Duration: #{response.dig("metadata", "duration_ms") || "N/A"}ms"
            puts "Tokens: #{response.dig("metadata", "token_count") || "N/A"}"
          end
        else
          output_data(response, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "history", "Show AI action execution history"
      option :project, type: :string, desc: "Filter by project ID"
      option :agent, type: :string, desc: "Filter by agent ID"
      option :status, type: :string, desc: "Filter by status (pending, running, completed, failed)"
      option :date_range, type: :string, default: "week", desc: "Date range (today, week, month)"
      option :limit, type: :numeric, default: 20, desc: "Maximum number of results"
      def history
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        params = {
          organization: org,
          per_page: options[:limit],
          date_range: options[:date_range]
        }
        params[:project_id] = options[:project] if options[:project]
        params[:agent_id] = options[:agent] if options[:agent]
        params[:status] = options[:status] if options[:status]

        response = client.get("/api/v1/ai_actions/executions", params: params)
        entries = response.fetch("executions", [])

        if output_format == "human"
          if entries.empty?
            warning "No execution history found."
            return
          end

          rows = entries.map do |entry|
            {
              id: entry["id"],
              agent: entry["agent_name"] || entry["agent_id"],
              status: colorize_status(entry["status"]),
              project: entry.dig("project", "name") || "-",
              user: entry.dig("user", "name") || "-",
              duration: entry["duration_ms"] ? "#{entry["duration_ms"]}ms" : "-",
              created_at: format_time(entry["created_at"])
            }
          end

          output_data(rows, headers: %i[id agent status project user duration created_at])

          pagination = response["pagination"]
          if pagination
            puts ""
            puts "Showing #{entries.size} of #{pagination["total"]} executions (page #{pagination["page"]})"
          end
        else
          output_data(response, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "cancel EXECUTION_ID", "Cancel a running AI action execution"
      def cancel(execution_id)
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        response = client.post(
          "/api/v1/ai_actions/executions/#{execution_id}/cancel",
          {},
          params: { organization: org }
        )

        if response["status"] == "cancelled"
          success "Execution #{execution_id} cancelled successfully."
        else
          error response["error"] || "Failed to cancel execution"
          exit 1
        end
      rescue StandardError => e
        handle_error(e)
      end

      no_commands do
        def format_endpoints(endpoints)
          Array(endpoints).map do |endpoint|
            [endpoint["name"], endpoint["type"]].compact.join(" (") + (endpoint["type"] ? ")" : "")
          end.join(", ")
        end

        def parse_input
          if options[:input_file]
            JSON.parse(File.read(options[:input_file]))
          elsif options[:input]
            JSON.parse(options[:input])
          else
            {}
          end
        rescue JSON::ParserError => e
          error "Invalid JSON input: #{e.message}"
          exit 1
        end

        def run_sync(org, project_id, agent_id, input)
          spinner = TTY::Spinner.new("[:spinner] Running agent #{agent_id}...", format: :dots)
          spinner.auto_spin

          response = client.post(
            "/api/v1/projects/#{project_id}/agents/#{agent_id}/run",
            { input: input },
            params: { organization: org }
          )

          spinner.success("Done!")

          if output_format == "human"
            puts ""
            puts pastel.bold("Result:")
            puts response.fetch("output", response)
            puts ""
            puts "Tokens: #{response.dig("metadata", "tokens") || "N/A"}"
            puts "Duration: #{response.dig("metadata", "duration_ms") || "N/A"}ms"
          else
            output_data(response, headers: nil)
          end
        end

        def run_streaming(org, project_id, agent_id, input)
          puts pastel.bold("Running agent #{agent_id} (streaming)...")
          puts ""

          client.post_streaming(
            "/api/v1/projects/#{project_id}/agents/#{agent_id}/run",
            { input: input, stream: true },
            params: { organization: org }
          ) do |chunk|
            print chunk
          end

          puts ""
        end

        def truncate_text(text, length)
          return "-" if text.nil? || text.empty?

          text.length > length ? "#{text[0...length]}..." : text
        end

        def colorize_status(status)
          case status&.to_s
          when "success", "completed", "ok"
            pastel.green(status)
          when "failed", "error"
            pastel.red(status)
          when "running", "in_progress"
            pastel.blue(status)
          when "pending", "queued"
            pastel.yellow(status)
          when "cancelled", "canceled"
            pastel.dim(status)
          else
            status || "-"
          end
        end

        def format_time(iso_time)
          return "-" unless iso_time

          Time.parse(iso_time).strftime("%Y-%m-%d %H:%M")
        rescue StandardError
          iso_time
        end
      end
    end
  end
end
