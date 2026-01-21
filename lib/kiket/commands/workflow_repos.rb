# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class WorkflowRepos < Base
      VALID_FREQUENCIES = %w[on_demand hourly daily].freeze

      desc "list", "List workflow repositories"
      option :project, type: :string, desc: "Filter by project ID"
      option :active, type: :boolean, desc: "Filter by active status"
      option :sync_status, type: :string, desc: "Filter by sync status"
      option :page, type: :numeric, default: 1, desc: "Page number"
      option :per_page, type: :numeric, default: 25, desc: "Items per page"
      def list
        ensure_authenticated!

        params = {}
        params[:project_id] = options[:project] if options[:project]
        params[:active] = options[:active].to_s if options.key?(:active)
        params[:sync_status] = options[:sync_status] if options[:sync_status]
        params[:page] = options[:page]
        params[:per_page] = options[:per_page]

        spinner = spinner("Fetching workflow repositories...")
        spinner.auto_spin

        response = client.get("/api/v1/workflow_repositories", params: params)
        repos = response.fetch("data", [])
        meta = response.fetch("meta", {})

        spinner.success("Found #{meta["total_count"] || repos.size} repository(ies)")

        if repos.empty?
          warning "No workflow repositories found"
          return
        end

        if output_format == "human"
          rows = repos.map do |r|
            {
              id: r["id"],
              repo: truncate_url(r["github_repo_url"], 35),
              branch: r["branch"] || "main",
              project: r["project_name"] || "—",
              status: format_sync_status(r["sync_status"]),
              active: r["active"] ? pastel.green("yes") : pastel.dim("no")
            }
          end
          output_data(rows, headers: %i[id repo branch project status active])

          if meta["total_pages"].to_i > 1
            puts ""
            puts pastel.dim("Page #{meta["current_page"]} of #{meta["total_pages"]} (#{meta["total_count"]} total)")
          end
        else
          output_data(repos, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "show REPO_ID", "Show workflow repository details"
      def show(repo_id)
        ensure_authenticated!

        spinner = spinner("Fetching workflow repository...")
        spinner.auto_spin

        response = client.get("/api/v1/workflow_repositories/#{repo_id}")
        repo = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Repository loaded")

        if output_format == "human"
          puts("\n#{pastel.bold("Workflow Repository ##{repo["id"]}")}")
          puts ""
          puts("GitHub URL: #{repo["github_repo_url"]}")
          puts("Branch: #{repo["branch"] || "main"}")
          puts("Workflow Path: #{repo["workflow_path"] || ".kiket/workflows"}")
          puts("Sync Frequency: #{repo["sync_frequency"] || "on_demand"}")
          puts("Sync Status: #{format_sync_status(repo["sync_status"])}")
          puts("Active: #{repo["active"] ? pastel.green("yes") : pastel.red("no")}")
          puts ""
          puts("Project: #{repo["project_name"] || "Not attached"} (ID: #{repo["project_id"] || "—"})")
          puts("Created by: #{repo["created_by_name"] || "Unknown"}")
          puts ""
          puts pastel.dim("Last synced: #{repo["last_synced_at"] || "Never"}")
          puts pastel.dim("Created: #{repo["created_at"]}")
          puts pastel.dim("Updated: #{repo["updated_at"]}")
        else
          output_json(repo)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "attach PROJECT_ID", "Attach a workflow repository to a project"
      option :url, type: :string, required: true, desc: "GitHub repository URL"
      option :branch, type: :string, default: "main", desc: "Branch to sync from"
      option :path, type: :string, default: ".kiket/workflows", desc: "Path to workflow files"
      option :frequency, type: :string, enum: VALID_FREQUENCIES, default: "on_demand", desc: "Sync frequency"
      option :token, type: :string, desc: "GitHub access token (optional)"
      def attach(project_id)
        ensure_authenticated!

        body = {
          workflow_repository: {
            github_repo_url: options[:url],
            branch: options[:branch],
            workflow_path: options[:path],
            sync_frequency: options[:frequency],
            github_token: options[:token],
            active: true
          }.compact
        }

        spinner = spinner("Attaching workflow repository...")
        spinner.auto_spin

        response = client.post("/api/v1/projects/#{project_id}/workflow_repositories", body: body)
        repo = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Workflow repository attached")

        if output_format == "human"
          success "Attached workflow repository to project"
          puts("  Repository: #{repo["github_repo_url"]}")
          puts("  Branch: #{repo["branch"]}")
          puts "  Sync started automatically"
        else
          output_json(repo)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "detach REPO_ID", "Detach (delete) a workflow repository"
      option :force, type: :boolean, aliases: "-f", desc: "Skip confirmation"
      def detach(repo_id)
        ensure_authenticated!

        unless options[:force]
          response = client.get("/api/v1/workflow_repositories/#{repo_id}")
          repo = response.is_a?(Hash) && response["data"] ? response["data"] : response

          unless prompt.yes?("Detach workflow repository '#{repo["github_repo_url"]}'? This will stop syncing workflows.")
            info "Cancelled"
            return
          end
        end

        spinner = spinner("Detaching workflow repository...")
        spinner.auto_spin

        client.delete("/api/v1/workflow_repositories/#{repo_id}")

        spinner.success("Workflow repository detached")
        success "Workflow repository has been detached"
      rescue StandardError => e
        handle_error(e)
      end

      desc "sync REPO_ID", "Trigger a sync for a workflow repository"
      def sync(repo_id)
        ensure_authenticated!

        spinner = spinner("Triggering sync...")
        spinner.auto_spin

        response = client.post("/api/v1/workflow_repositories/#{repo_id}/sync", body: {})
        result = response.is_a?(Hash) ? response : { message: "Sync started" }

        spinner.success("Sync triggered")

        if output_format == "human"
          success result["message"] || "Sync started"
          if result["workflow_repository"]
            puts("  Repository: #{result["workflow_repository"]["github_repo_url"]}")
            puts("  Status: #{format_sync_status(result["workflow_repository"]["sync_status"])}")
          end
        else
          output_json(result)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "update REPO_ID", "Update a workflow repository"
      option :branch, type: :string, desc: "New branch"
      option :path, type: :string, desc: "New workflow path"
      option :frequency, type: :string, enum: VALID_FREQUENCIES, desc: "New sync frequency"
      option :active, type: :boolean, desc: "Set active status"
      option :project, type: :string, desc: "New project ID to attach to"
      def update(repo_id)
        ensure_authenticated!

        updates = {
          branch: options[:branch],
          workflow_path: options[:path],
          sync_frequency: options[:frequency],
          active: options[:active],
          project_id: options[:project]
        }.compact

        if updates.empty?
          error "No updates provided. Use --branch, --path, --frequency, --active, or --project"
          exit 1
        end

        body = { workflow_repository: updates }

        spinner = spinner("Updating workflow repository...")
        spinner.auto_spin

        response = client.patch("/api/v1/workflow_repositories/#{repo_id}", body: body)
        repo = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Workflow repository updated")

        if output_format == "human"
          success "Updated workflow repository ##{repo["id"]}"
          puts("  Repository: #{repo["github_repo_url"]}")
          puts("  Branch: #{repo["branch"]}")
          puts("  Active: #{repo["active"] ? "yes" : "no"}")
        else
          output_json(repo)
        end
      rescue StandardError => e
        handle_error(e)
      end

      private

      def format_sync_status(status)
        return "—" unless status

        case status.to_s.downcase
        when "success", "synced"
          pastel.green(status)
        when "syncing", "queued", "in_progress"
          pastel.yellow(status)
        when "failed", "error"
          pastel.red(status)
        when "pending"
          pastel.dim(status)
        else
          status
        end
      end

      def truncate_url(url, max_length)
        return url if url.nil? || url.length <= max_length

        # Remove protocol and try to keep the repo path
        short = url.gsub(%r{^https?://}, "")
        return short if short.length <= max_length

        "...#{short[-(max_length - 3)..]}"
      end
    end
  end
end
