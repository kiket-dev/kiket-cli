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

      desc "run AGENT_ID", "Execute an agent with the specified input"
      option :project, type: :string, required: true, desc: "Project ID or slug"
      option :input, type: :string, desc: "JSON input payload"
      option :input_file, type: :string, desc: "Path to JSON file with input payload"
      option :stream, type: :boolean, default: false, desc: "Stream output as it arrives"
      def run(agent_id)
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
          puts "Plan: #{response.dig('plan', 'name') || 'Unknown'}"
          puts "Billing period: #{response['billing_period'] || 'Monthly'}"
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

        if options[:category]
          entries = entries.select { |e| e.dig("metadata", "category") == options[:category] }
        end

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

      no_commands do
        def format_endpoints(endpoints)
          Array(endpoints).map do |endpoint|
            [ endpoint["name"], endpoint["type"] ].compact.join(" (") + (endpoint["type"] ? ")" : "")
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
            puts "Tokens: #{response.dig('metadata', 'tokens') || 'N/A'}"
            puts "Duration: #{response.dig('metadata', 'duration_ms') || 'N/A'}ms"
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
      end
    end
  end
end
