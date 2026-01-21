# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Sync < Base
      desc "project PROJECT_ID", "Sync a project's workflow repository"
      option :wait, type: :boolean, aliases: "-w", desc: "Wait for sync to complete"
      option :timeout, type: :numeric, default: 60, desc: "Timeout in seconds when waiting"
      def project(project_id)
        ensure_authenticated!

        # First, find the project's workflow repositories
        spinner = spinner("Finding workflow repositories for project...")
        spinner.auto_spin

        response = client.get("/api/v1/workflow_repositories", params: { project_id: project_id })
        repos = response.fetch("data", [])

        if repos.empty?
          spinner.error("No workflow repositories found")
          warning "Project #{project_id} has no attached workflow repositories"
          return
        end

        spinner.success("Found #{repos.size} workflow repository(ies)")

        repos.each do |repo|
          sync_repository(repo, wait: options[:wait], timeout: options[:timeout])
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "repo REPO_ID", "Sync a specific workflow repository"
      option :wait, type: :boolean, aliases: "-w", desc: "Wait for sync to complete"
      option :timeout, type: :numeric, default: 60, desc: "Timeout in seconds when waiting"
      def repo(repo_id)
        ensure_authenticated!

        spinner = spinner("Fetching repository...")
        spinner.auto_spin

        response = client.get("/api/v1/workflow_repositories/#{repo_id}")
        repo = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Repository found")

        sync_repository(repo, wait: options[:wait], timeout: options[:timeout])
      rescue StandardError => e
        handle_error(e)
      end

      desc "all", "Sync all active workflow repositories in the organization"
      option :wait, type: :boolean, aliases: "-w", desc: "Wait for each sync to complete"
      option :timeout, type: :numeric, default: 60, desc: "Timeout in seconds when waiting"
      def all
        ensure_authenticated!

        spinner = spinner("Fetching active workflow repositories...")
        spinner.auto_spin

        response = client.get("/api/v1/workflow_repositories", params: { active: "true", per_page: 100 })
        repos = response.fetch("data", [])

        if repos.empty?
          spinner.error("No repositories found")
          warning "No active workflow repositories found"
          return
        end

        spinner.success("Found #{repos.size} active repository(ies)")

        repos.each_with_index do |repo, index|
          puts "" if index.positive?
          sync_repository(repo, wait: options[:wait], timeout: options[:timeout])
        end
      rescue StandardError => e
        handle_error(e)
      end

      default_task :project

      private

      def sync_repository(repo, wait:, timeout:)
        info "Syncing #{repo["github_repo_url"]} (#{repo["branch"] || "main"})..."

        spinner = spinner("Triggering sync...")
        spinner.auto_spin

        client.post("/api/v1/workflow_repositories/#{repo["id"]}/sync", body: {})

        spinner.success("Sync triggered")

        if wait
          wait_for_sync(repo["id"], timeout)
        else
          success "Sync started for repository ##{repo["id"]}"
          puts "  Use --wait to wait for completion, or check status with:"
          puts("  kiket workflow-repo show #{repo["id"]}")
        end
      end

      def wait_for_sync(repo_id, timeout)
        spinner = spinner("Waiting for sync to complete...")
        spinner.auto_spin

        start_time = Time.zone.now
        loop do
          response = client.get("/api/v1/workflow_repositories/#{repo_id}")
          repo = response.is_a?(Hash) && response["data"] ? response["data"] : response

          status = repo["sync_status"].to_s.downcase

          case status
          when "success", "synced"
            spinner.success("Sync completed successfully")
            success "Repository ##{repo_id} synced successfully"
            puts("  Last synced: #{repo["last_synced_at"]}")
            return
          when "failed", "error"
            spinner.error("Sync failed")
            error "Repository ##{repo_id} sync failed"
            return
          end

          if Time.zone.now - start_time > timeout
            spinner.error("Timeout")
            warning "Sync still in progress after #{timeout}s. Check status with:"
            puts("  kiket workflow-repo show #{repo_id}")
            return
          end

          sleep 2
        end
      end
    end
  end
end
