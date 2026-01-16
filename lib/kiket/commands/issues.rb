# frozen_string_literal: true

require_relative "base"
require "multi_json"

module Kiket
  module Commands
    class Issues < Base
      VALID_PRIORITIES = %w[lowest low medium high highest critical].freeze
      VALID_TYPES = %w[task bug story epic subtask].freeze

      desc "list PROJECT_ID", "List issues for a project"
      option :status, type: :string, desc: "Filter by status"
      option :type, type: :string, desc: "Filter by issue type"
      option :assignee, type: :string, desc: "Filter by assignee ID"
      option :label, type: :string, desc: "Filter by label"
      option :search, type: :string, desc: "Search in title"
      option :page, type: :numeric, default: 1, desc: "Page number"
      option :per_page, type: :numeric, default: 25, desc: "Items per page"
      def list(project_id)
        ensure_authenticated!

        params = { project_id: project_id }
        params[:status] = options[:status] if options[:status]
        params[:issue_type] = options[:type] if options[:type]
        params[:assigned_to] = options[:assignee] if options[:assignee]
        params[:label] = options[:label] if options[:label]
        params[:search] = options[:search] if options[:search]
        params[:page] = options[:page]
        params[:per_page] = options[:per_page]

        spinner = spinner("Fetching issues...")
        spinner.auto_spin

        response = client.get("/api/v1/issues", params: params)
        issues = response.fetch("data", [])
        meta = response.fetch("meta", {})

        spinner.success("Found #{meta["total_count"] || issues.size} issue(s)")

        if issues.empty?
          warning "No issues found"
          return
        end

        if output_format == "human"
          rows = issues.map do |i|
            {
              key: i["key"] || i["id"],
              title: truncate(i["title"], 40),
              status: format_status(i["status"]),
              type: i["issue_type"],
              priority: format_priority(i["priority"]),
              assignee: i.dig("assignee", "name") || "—"
            }
          end
          output_data(rows, headers: %i[key title status type priority assignee])

          if meta["total_pages"].to_i > 1
            puts ""
            puts pastel.dim("Page #{meta["current_page"]} of #{meta["total_pages"]} (#{meta["total_count"]} total)")
          end
        else
          output_data(issues, headers: nil)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "show ISSUE_KEY", "Show issue details"
      def show(issue_key)
        ensure_authenticated!

        spinner = spinner("Fetching issue...")
        spinner.auto_spin

        response = client.get("/api/v1/issues/#{issue_key}")
        issue = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Issue loaded")

        if output_format == "human"
          puts "\n#{pastel.bold(issue["key"] || issue["id"])}: #{issue["title"]}"
          puts ""
          puts "Status: #{format_status(issue["status"])}"
          puts "Type: #{issue["issue_type"]}"
          puts "Priority: #{format_priority(issue["priority"])}"
          puts "Project: #{issue["project_key"]}"
          puts "Assignee: #{issue.dig("assignee", "name") || "Unassigned"}"
          puts "Due Date: #{issue["due_date"] || "Not set"}"

          puts "Parent: #{issue["parent_key"] || issue["parent_id"]}" if issue["parent_id"]

          puts "Labels: #{issue["labels"].join(", ")}" if issue["labels"]&.any?

          if issue["custom_fields"]&.any?
            puts ""
            puts pastel.bold("Custom Fields:")
            issue["custom_fields"].each do |key, value|
              puts "  #{key}: #{value}"
            end
          end

          if issue["description"].to_s.strip != ""
            puts ""
            puts pastel.bold("Description:")
            puts issue["description"]
          end

          puts ""
          puts pastel.dim("Created: #{issue["created_at"]}")
          puts pastel.dim("Updated: #{issue["updated_at"]}")
        else
          output_json(issue)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "create PROJECT_ID", "Create a new issue"
      option :title, type: :string, required: true, desc: "Issue title"
      option :description, type: :string, desc: "Issue description"
      option :type, type: :string, default: "task", desc: "Issue type (e.g., Epic, UserStory, Task, Bug)"
      option :priority, type: :string, enum: VALID_PRIORITIES, default: "medium", desc: "Priority"
      option :status, type: :string, desc: "Initial status (default: backlog)"
      option :assignee, type: :string, desc: "Assignee ID"
      option :due_date, type: :string, desc: "Due date (YYYY-MM-DD)"
      option :labels, type: :array, desc: "Labels (space-separated)"
      option :parent, type: :string, desc: "Parent issue ID"
      option :custom_fields, type: :string, desc: "Custom fields as JSON (e.g., '{\"field_key\":\"value\"}')"
      def create(project_id)
        ensure_authenticated!

        body = {
          issue: {
            project_id: project_id,
            title: options[:title],
            description: options[:description],
            issue_type: options[:type],
            priority: options[:priority],
            status: options[:status],
            assigned_to: options[:assignee],
            due_date: options[:due_date],
            labels: options[:labels],
            parent_id: options[:parent],
            custom_fields: parse_custom_fields(options[:custom_fields])
          }.compact
        }

        spinner = spinner("Creating issue...")
        spinner.auto_spin

        response = client.post("/api/v1/issues", body: body)
        issue = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Issue created")

        if output_format == "human"
          success "Created issue '#{issue["title"]}' (#{issue["key"] || issue["id"]})"
          puts "  Type: #{issue["issue_type"]}"
          puts "  Status: #{format_status(issue["status"])}"
          puts "  Priority: #{format_priority(issue["priority"])}"
        else
          output_json(issue)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "update ISSUE_KEY", "Update an issue"
      option :title, type: :string, desc: "New title"
      option :description, type: :string, desc: "New description"
      option :type, type: :string, desc: "New type"
      option :priority, type: :string, enum: VALID_PRIORITIES, desc: "New priority"
      option :status, type: :string, desc: "New status"
      option :assignee, type: :string, desc: "New assignee ID"
      option :due_date, type: :string, desc: "New due date (YYYY-MM-DD)"
      option :labels, type: :array, desc: "New labels"
      option :parent, type: :string, desc: "New parent issue ID"
      option :custom_fields, type: :string, desc: "Custom fields as JSON"
      def update(issue_key)
        ensure_authenticated!

        updates = {
          title: options[:title],
          description: options[:description],
          issue_type: options[:type],
          priority: options[:priority],
          status: options[:status],
          assigned_to: options[:assignee],
          due_date: options[:due_date],
          labels: options[:labels],
          parent_id: options[:parent],
          custom_fields: parse_custom_fields(options[:custom_fields])
        }.compact

        if updates.empty?
          error "No updates provided. Use --title, --description, --type, --priority, --status, --assignee, --due-date, --labels, --parent, or --custom-fields"
          exit 1
        end

        body = { issue: updates }

        spinner = spinner("Updating issue...")
        spinner.auto_spin

        response = client.patch("/api/v1/issues/#{issue_key}", body: body)
        issue = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Issue updated")

        if output_format == "human"
          success "Updated issue '#{issue["title"]}' (#{issue["key"] || issue["id"]})"
          puts "  Status: #{format_status(issue["status"])}"
          puts "  Priority: #{format_priority(issue["priority"])}"
        else
          output_json(issue)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "transition ISSUE_KEY STATE", "Transition issue to a new workflow state"
      def transition(issue_key, target_state)
        ensure_authenticated!

        body = {
          transition: { state: target_state }
        }

        spinner = spinner("Transitioning issue...")
        spinner.auto_spin

        response = client.post("/api/v1/issues/#{issue_key}/transition", body: body)
        issue = response.is_a?(Hash) && response["data"] ? response["data"] : response

        spinner.success("Issue transitioned")

        if output_format == "human"
          success "Transitioned '#{issue["key"] || issue["id"]}' to #{format_status(issue["status"])}"
        else
          output_json(issue)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "delete ISSUE_KEY", "Delete an issue"
      option :force, type: :boolean, aliases: "-f", desc: "Skip confirmation"
      def delete(issue_key)
        ensure_authenticated!

        unless options[:force]
          response = client.get("/api/v1/issues/#{issue_key}")
          issue = response.is_a?(Hash) && response["data"] ? response["data"] : response

          unless prompt.yes?("Delete issue '#{issue["title"]}'? This cannot be undone.")
            info "Cancelled"
            return
          end
        end

        spinner = spinner("Deleting issue...")
        spinner.auto_spin

        client.delete("/api/v1/issues/#{issue_key}")

        spinner.success("Issue deleted")
        success "Issue #{issue_key} has been deleted"
      rescue StandardError => e
        handle_error(e)
      end

      desc "schema PROJECT_ID", "Show issue schema (types, fields, statuses)"
      def schema(project_id)
        ensure_authenticated!

        spinner = spinner("Fetching issue schema...")
        spinner.auto_spin

        response = client.get("/api/v1/issues/schema", params: { project_id: project_id })

        spinner.success("Schema loaded")

        if output_format == "human"
          puts ""
          puts pastel.bold("Issue Types:")
          (response["issue_types"] || []).each do |t|
            puts "  #{t["name"]} - #{t["description"] || "No description"}"
          end

          puts ""
          puts pastel.bold("Statuses:")
          (response["statuses"] || []).each do |s|
            puts "  #{s["name"]} (#{s["category"] || "—"})"
          end

          puts ""
          puts pastel.bold("Priorities:")
          puts "  #{(response["priorities"] || VALID_PRIORITIES).join(", ")}"

          if (custom_fields = response["custom_fields"])&.any?
            puts ""
            puts pastel.bold("Custom Fields:")
            custom_fields.each do |f|
              puts "  #{f["key"]} (#{f["field_type"]}) - #{f["name"]}"
            end
          end
        else
          output_json(response)
        end
      rescue StandardError => e
        handle_error(e)
      end

      # Comments subcommands
      desc "comments SUBCOMMAND ...ARGS", "Manage issue comments"
      subcommand "comments", Class.new(Base) {
        desc "list ISSUE_KEY", "List comments on an issue"
        def list(issue_key)
          ensure_authenticated!

          spinner = spinner("Fetching comments...")
          spinner.auto_spin

          response = client.get("/api/v1/issues/#{issue_key}/comments")
          comments = response.is_a?(Array) ? response : (response["comments"] || response["data"] || [])

          spinner.success("Found #{comments.size} comment(s)")

          if comments.empty?
            warning "No comments found"
            return
          end

          if output_format == "human"
            comments.each_with_index do |c, idx|
              puts "" if idx.positive?
              puts pastel.bold("##{c["id"]} by #{c.dig("author", "name") || "Unknown"}")
              puts pastel.dim(c["created_at"])
              puts c["body"]
            end
          else
            output_json(comments)
          end
        rescue StandardError => e
          handle_error(e)
        end

        desc "add ISSUE_KEY BODY", "Add a comment to an issue"
        def add(issue_key, body)
          ensure_authenticated!

          spinner = spinner("Adding comment...")
          spinner.auto_spin

          response = client.post("/api/v1/issues/#{issue_key}/comments", body: { comment: { body: body } })
          comment = response.is_a?(Hash) && response["comment"] ? response["comment"] : response

          spinner.success("Comment added")

          if output_format == "human"
            success "Added comment ##{comment["id"]}"
          else
            output_json(comment)
          end
        rescue StandardError => e
          handle_error(e)
        end

        desc "update ISSUE_KEY COMMENT_ID BODY", "Update a comment"
        def update(issue_key, comment_id, body)
          ensure_authenticated!

          spinner = spinner("Updating comment...")
          spinner.auto_spin

          response = client.patch("/api/v1/issues/#{issue_key}/comments/#{comment_id}", body: { comment: { body: body } })
          comment = response.is_a?(Hash) && response["comment"] ? response["comment"] : response

          spinner.success("Comment updated")

          if output_format == "human"
            success "Updated comment ##{comment["id"]}"
          else
            output_json(comment)
          end
        rescue StandardError => e
          handle_error(e)
        end

        desc "delete ISSUE_KEY COMMENT_ID", "Delete a comment"
        option :force, type: :boolean, aliases: "-f", desc: "Skip confirmation"
        def delete(issue_key, comment_id)
          ensure_authenticated!

          if !options[:force] && !prompt.yes?("Delete comment ##{comment_id}? This cannot be undone.")
            info "Cancelled"
            return
          end

          spinner = spinner("Deleting comment...")
          spinner.auto_spin

          client.delete("/api/v1/issues/#{issue_key}/comments/#{comment_id}")

          spinner.success("Comment deleted")
          success "Comment ##{comment_id} has been deleted"
        rescue StandardError => e
          handle_error(e)
        end
      }

      private

      def parse_custom_fields(json_str)
        return nil if json_str.nil? || json_str.empty?

        MultiJson.load(json_str)
      rescue MultiJson::ParseError => e
        error "Invalid JSON for custom_fields: #{e.message}"
        exit 1
      end

      def format_status(status)
        return status unless status

        case status.to_s.downcase
        when "open", "todo", "backlog"
          pastel.cyan(status)
        when "in_progress", "in progress", "doing"
          pastel.yellow(status)
        when "done", "closed", "completed"
          pastel.green(status)
        when "blocked"
          pastel.red(status)
        else
          status
        end
      end

      def format_priority(priority)
        return "—" unless priority

        case priority.to_s.downcase
        when "highest", "critical"
          pastel.red.bold(priority)
        when "high"
          pastel.red(priority)
        when "medium"
          pastel.yellow(priority)
        when "low"
          pastel.cyan(priority)
        when "lowest"
          pastel.dim(priority)
        else
          priority
        end
      end

      def truncate(str, max_length)
        return str if str.nil? || str.length <= max_length

        "#{str[0, max_length - 3]}..."
      end
    end
  end
end
