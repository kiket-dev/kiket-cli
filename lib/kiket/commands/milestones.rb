# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Milestones < Base
      VALID_STATUSES = %w[planning active completed cancelled].freeze

      desc "list PROJECT_ID", "List milestones for a project"
      option :status, type: :string, enum: VALID_STATUSES, desc: "Filter by status"
      def list(project_id)
        ensure_authenticated!

        params = {}
        params[:status] = options[:status] if options[:status]

        spinner = spinner("Fetching milestones...")
        spinner.auto_spin

        response = client.get("/api/v1/projects/#{project_id}/milestones", params: params)
        milestones = response.fetch("milestones", [])

        spinner.success("Found #{milestones.size} milestone(s)")

        if milestones.empty?
          warning "No milestones found for project #{project_id}"
          return
        end

        if output_format == "human"
          rows = milestones.map do |m|
            {
              id: m["id"],
              name: truncate(m["name"], 30),
              status: format_status(m["status"]),
              progress: "#{m["progress"]}%",
              target_date: m["target_date"] || "—",
              issues: "#{m["completed_issue_count"] || 0}/#{m["issue_count"] || 0}",
              days_left: format_days_remaining(m["days_remaining"], m["overdue"])
            }
          end
          output_data(rows, headers: %i[id name status progress target_date issues days_left])
        else
          output_data(milestones, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "show PROJECT_ID MILESTONE_ID", "Show milestone details"
      def show(project_id, milestone_id)
        ensure_authenticated!

        spinner = spinner("Fetching milestone...")
        spinner.auto_spin

        response = client.get("/api/v1/projects/#{project_id}/milestones/#{milestone_id}")
        milestone = response.fetch("milestone", response)

        spinner.success("Milestone loaded")

        if output_format == "human"
          puts "\n#{pastel.bold(milestone["name"])}"
          puts "ID: #{milestone["id"]}"
          puts "Status: #{format_status(milestone["status"])}"
          puts "Progress: #{milestone["progress"]}%"
          puts "Target Date: #{milestone["target_date"] || "Not set"}"
          puts "Version: #{milestone["version"] || "—"}"
          puts ""
          puts "Issues: #{milestone["completed_issue_count"] || 0}/#{milestone["issue_count"] || 0} completed"
          puts "Days Remaining: #{format_days_remaining(milestone["days_remaining"], milestone["overdue"])}"
          puts ""
          if milestone["description"].to_s.strip != ""
            puts pastel.bold("Description:")
            puts milestone["description"]
          end
          puts ""
          puts pastel.dim("Created: #{milestone["created_at"]}")
          puts pastel.dim("Updated: #{milestone["updated_at"]}")
        else
          output_json(milestone)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "create PROJECT_ID", "Create a new milestone"
      option :name, type: :string, required: true, desc: "Milestone name"
      option :description, type: :string, desc: "Milestone description"
      option :target_date, type: :string, desc: "Target date (YYYY-MM-DD)"
      option :status, type: :string, enum: VALID_STATUSES, default: "planning", desc: "Initial status"
      option :version, type: :string, desc: "Version string (e.g., v1.0.0)"
      def create(project_id)
        ensure_authenticated!

        body = {
          milestone: {
            name: options[:name],
            description: options[:description],
            target_date: options[:target_date],
            status: options[:status],
            version: options[:version]
          }.compact
        }

        spinner = spinner("Creating milestone...")
        spinner.auto_spin

        response = client.post("/api/v1/projects/#{project_id}/milestones", body: body)
        milestone = response.fetch("milestone", response)

        spinner.success("Milestone created")

        if output_format == "human"
          success "Created milestone '#{milestone["name"]}' (ID: #{milestone["id"]})"
          puts "  Status: #{format_status(milestone["status"])}"
          puts "  Target Date: #{milestone["target_date"] || "Not set"}"
        else
          output_json(milestone)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "update PROJECT_ID MILESTONE_ID", "Update a milestone"
      option :name, type: :string, desc: "New name"
      option :description, type: :string, desc: "New description"
      option :target_date, type: :string, desc: "New target date (YYYY-MM-DD)"
      option :status, type: :string, enum: VALID_STATUSES, desc: "New status"
      option :version, type: :string, desc: "New version string"
      def update(project_id, milestone_id)
        ensure_authenticated!

        updates = {
          name: options[:name],
          description: options[:description],
          target_date: options[:target_date],
          status: options[:status],
          version: options[:version]
        }.compact

        if updates.empty?
          error "No updates provided. Use --name, --description, --target-date, --status, or --version"
          exit 1
        end

        body = { milestone: updates }

        spinner = spinner("Updating milestone...")
        spinner.auto_spin

        response = client.patch("/api/v1/projects/#{project_id}/milestones/#{milestone_id}", body: body)
        milestone = response.fetch("milestone", response)

        spinner.success("Milestone updated")

        if output_format == "human"
          success "Updated milestone '#{milestone["name"]}' (ID: #{milestone["id"]})"
          puts "  Status: #{format_status(milestone["status"])}"
          puts "  Progress: #{milestone["progress"]}%"
        else
          output_json(milestone)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "delete PROJECT_ID MILESTONE_ID", "Delete a milestone"
      option :force, type: :boolean, aliases: "-f", desc: "Skip confirmation"
      def delete(project_id, milestone_id)
        ensure_authenticated!

        unless options[:force]
          response = client.get("/api/v1/projects/#{project_id}/milestones/#{milestone_id}")
          milestone = response.fetch("milestone", response)

          unless prompt.yes?("Delete milestone '#{milestone["name"]}'? This cannot be undone.")
            info "Cancelled"
            return
          end
        end

        spinner = spinner("Deleting milestone...")
        spinner.auto_spin

        client.delete("/api/v1/projects/#{project_id}/milestones/#{milestone_id}")

        spinner.success("Milestone deleted")
        success "Milestone #{milestone_id} has been deleted"
      rescue StandardError => e
        handle_error(e)
      end

      private

      def format_status(status)
        case status
        when "planning"
          pastel.cyan(status)
        when "active"
          pastel.green(status)
        when "completed"
          pastel.blue(status)
        when "cancelled"
          pastel.dim(status)
        else
          status
        end
      end

      def format_days_remaining(days, overdue)
        return "—" if days.nil?

        if overdue
          pastel.red("#{days.abs}d overdue")
        elsif days <= 7
          pastel.yellow("#{days}d")
        else
          "#{days}d"
        end
      end

      def truncate(str, max_length)
        return str if str.nil? || str.length <= max_length

        "#{str[0, max_length - 1]}..."
      end
    end
  end
end
