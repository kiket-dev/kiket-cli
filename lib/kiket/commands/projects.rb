# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Projects < Base
      VALID_VISIBILITIES = %w[private team public].freeze

      desc "list", "List projects in the organization"
      option :status, type: :string, desc: "Filter by status"
      option :visibility, type: :string, desc: "Filter by visibility (private, team, public)"
      option :search, type: :string, desc: "Search by name"
      option :page, type: :numeric, default: 1, desc: "Page number"
      option :per_page, type: :numeric, default: 25, desc: "Items per page"
      def list
        ensure_authenticated!

        params = {}
        params[:status] = options[:status] if options[:status]
        params[:visibility] = options[:visibility] if options[:visibility]
        params[:search] = options[:search] if options[:search]
        params[:page] = options[:page]
        params[:per_page] = options[:per_page]

        spinner = spinner("Fetching projects...")
        spinner.auto_spin

        response = client.get("/api/v1/projects", params: params)
        projects = response.fetch("data", [])
        meta = response.fetch("meta", {})

        spinner.success("Found #{meta["total_count"] || projects.size} project(s)")

        if projects.empty?
          warning "No projects found"
          return
        end

        if output_format == "human"
          rows = projects.map do |p|
            {
              id: p["id"],
              key: p["project_key"] || "—",
              name: truncate(p["name"], 30),
              status: p["status"] || "—",
              visibility: format_visibility(p["visibility"])
            }
          end
          output_data(rows, headers: %i[id key name status visibility])

          if meta["total_pages"].to_i > 1
            puts ""
            puts pastel.dim("Page #{meta["current_page"]} of #{meta["total_pages"]} (#{meta["total_count"]} total)")
          end
        else
          output_data(projects, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "show PROJECT_ID", "Show project details"
      def show(project_id)
        ensure_authenticated!

        spinner = spinner("Fetching project...")
        spinner.auto_spin

        response = client.get("/api/v1/projects/#{project_id}")
        project = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Project loaded")

        if output_format == "human"
          puts("\n#{pastel.bold(project["name"])}")
          puts ""
          puts("ID: #{project["id"]}")
          puts("Key: #{project["project_key"] || "Not set"}")
          puts("Status: #{project["status"] || "Not set"}")
          puts("Visibility: #{format_visibility(project["visibility"])}")

          if project["description"].to_s.strip != ""
            puts ""
            puts pastel.bold("Description:")
            puts project["description"]
          end

          puts ""
          puts pastel.dim("Created: #{project["created_at"]}")
          puts pastel.dim("Updated: #{project["updated_at"]}")
        else
          output_json(project)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "create", "Create a new project"
      option :name, type: :string, required: true, desc: "Project name"
      option :description, type: :string, desc: "Project description"
      option :key, type: :string, desc: "Project key (e.g., PROJ)"
      option :visibility, type: :string, enum: VALID_VISIBILITIES, default: "private", desc: "Visibility"
      option :github_repo, type: :string, desc: "GitHub repository URL"
      option :start_date, type: :string, desc: "Start date (YYYY-MM-DD)"
      option :end_date, type: :string, desc: "End date (YYYY-MM-DD)"
      def create
        ensure_authenticated!

        body = {
          project: {
            name: options[:name],
            description: options[:description],
            project_key: options[:key],
            visibility: options[:visibility],
            github_repo_url: options[:github_repo],
            start_date: options[:start_date],
            end_date: options[:end_date]
          }.compact
        }

        spinner = spinner("Creating project...")
        spinner.auto_spin

        response = client.post("/api/v1/projects", body: body)
        project = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Project created")

        if output_format == "human"
          success "Created project '#{project["name"]}' (ID: #{project["id"]})"
          puts("  Key: #{project["project_key"] || "Not set"}")
          puts("  Visibility: #{format_visibility(project["visibility"])}")
        else
          output_json(project)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "update PROJECT_ID", "Update a project"
      option :name, type: :string, desc: "New name"
      option :description, type: :string, desc: "New description"
      option :key, type: :string, desc: "New project key"
      option :status, type: :string, desc: "New status"
      option :visibility, type: :string, enum: VALID_VISIBILITIES, desc: "New visibility"
      option :start_date, type: :string, desc: "New start date (YYYY-MM-DD)"
      option :end_date, type: :string, desc: "New end date (YYYY-MM-DD)"
      def update(project_id)
        ensure_authenticated!

        updates = {
          name: options[:name],
          description: options[:description],
          project_key: options[:key],
          status: options[:status],
          visibility: options[:visibility],
          start_date: options[:start_date],
          end_date: options[:end_date]
        }.compact

        if updates.empty?
          error "No updates provided. Use --name, --description, --key, --status, --visibility, --start-date, or --end-date"
          exit 1
        end

        body = { project: updates }

        spinner = spinner("Updating project...")
        spinner.auto_spin

        response = client.patch("/api/v1/projects/#{project_id}", body: body)
        project = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Project updated")

        if output_format == "human"
          success "Updated project '#{project["name"]}' (ID: #{project["id"]})"
        else
          output_json(project)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "archive PROJECT_ID", "Archive a project (sets status to 'archived')"
      option :force, type: :boolean, aliases: "-f", desc: "Skip confirmation"
      def archive(project_id)
        ensure_authenticated!

        unless options[:force]
          response = client.get("/api/v1/projects/#{project_id}")
          project = response.is_a?(Hash) && response["data"] ? response["data"] : response

          unless prompt.yes?("Archive project '#{project["name"]}'?")
            info "Cancelled"
            return
          end
        end

        body = { project: { status: "archived" } }

        spinner = spinner("Archiving project...")
        spinner.auto_spin

        response = client.patch("/api/v1/projects/#{project_id}", body: body)
        project = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Project archived")
        success "Project '#{project["name"]}' has been archived"
      rescue StandardError => e
        handle_error(e)
      end

      desc "delete PROJECT_ID", "Delete a project permanently"
      option :force, type: :boolean, aliases: "-f", desc: "Skip confirmation"
      def delete(project_id)
        ensure_authenticated!

        unless options[:force]
          response = client.get("/api/v1/projects/#{project_id}")
          project = response.is_a?(Hash) && response["data"] ? response["data"] : response

          warning "This will permanently delete all issues, boards, and data in this project!"
          unless prompt.yes?("Delete project '#{project["name"]}'? This cannot be undone.")
            info "Cancelled"
            return
          end
        end

        spinner = spinner("Deleting project...")
        spinner.auto_spin

        client.delete("/api/v1/projects/#{project_id}")

        spinner.success("Project deleted")
        success "Project has been permanently deleted"
      rescue StandardError => e
        handle_error(e)
      end

      private

      def format_visibility(visibility)
        return "—" unless visibility

        case visibility.to_s.downcase
        when "public"
          pastel.green(visibility)
        when "team"
          pastel.cyan(visibility)
        when "private"
          pastel.yellow(visibility)
        else
          visibility
        end
      end

      def truncate(str, max_length)
        return str if str.nil? || str.length <= max_length

        "#{str[0, max_length - 3]}..."
      end
    end
  end
end
