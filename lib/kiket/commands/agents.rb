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

      no_commands do
        def format_endpoints(endpoints)
          Array(endpoints).map do |endpoint|
            [ endpoint["name"], endpoint["type"] ].compact.join(" (") + (endpoint["type"] ? ")" : "")
          end.join(", ")
        end
      end
    end
  end
end
