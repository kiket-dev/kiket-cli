# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Intakes < Base
      desc "list", "List intake forms for a project"
      option :project, type: :string, required: true, desc: "Project ID"
      option :active, type: :boolean, desc: "Filter by active forms only"
      option :public, type: :boolean, desc: "Filter by public forms only"
      option :limit, type: :numeric, desc: "Max forms to return"
      def list
        ensure_authenticated!
        org = organization
        unless org
          error "Organization required (use --org or set a default with 'kiket configure org')"
          exit 1
        end

        params = {
          organization: org,
          project_id: options[:project],
          active: options[:active],
          public: options[:public],
          limit: options[:limit]
        }.compact

        spinner = spinner("Fetching intake forms...")
        spinner.auto_spin

        response = client.get("/api/v1/intake_forms", params: params)

        spinner.success("Fetched forms")

        rows = response.fetch("data", []).map do |form|
          {
            id: form["id"],
            key: form["key"],
            name: form["name"],
            slug: form["slug"],
            active: form["active"],
            public: form["public"],
            embed_enabled: form["embed_enabled"],
            submissions_count: form.dig("stats", "submissions_count") || "-",
            created_at: form["created_at"]
          }
        end

        if rows.empty?
          puts pastel.yellow("No intake forms found.")
          return
        end

        headers = %i[id key name slug active public embed_enabled submissions_count created_at]
        output_data(rows, headers:)
      rescue StandardError => e
        handle_error(e)
      end

      desc "show FORM_KEY", "Show details of an intake form"
      option :project, type: :string, required: true, desc: "Project ID"
      def show(form_key)
        ensure_authenticated!
        org = organization
        unless org
          error "Organization required (use --org or set a default with 'kiket configure org')"
          exit 1
        end

        spinner = spinner("Fetching form details...")
        spinner.auto_spin

        response = client.get("/api/v1/intake_forms/#{form_key}", params: {
          organization: org,
          project_id: options[:project]
        })

        spinner.success("Fetched form")

        form = response.fetch("data", {})
        fields = form.fetch("fields", [])

        puts
        puts pastel.bold("Form: #{form['name']}")
        puts "-" * 50
        puts "ID:            #{form['id']}"
        puts "Key:           #{form['key']}"
        puts "Slug:          #{form['slug']}"
        puts "Active:        #{form['active']}"
        puts "Public:        #{form['public']}"
        puts "Embed:         #{form['embed_enabled']}"
        puts "Rate Limit:    #{form['rate_limit']}/hour"
        puts "Approval:      #{form['requires_approval'] ? 'Required' : 'Auto-process'}"
        puts "Created:       #{form['created_at']}"

        if form["form_url"]
          puts
          puts pastel.cyan("Form URL: #{form['form_url']}")
        end

        if fields.any?
          puts
          puts pastel.bold("Fields (#{fields.size}):")
          fields.each do |field|
            required = field["required"] ? " (required)" : ""
            puts "  • #{field['label']} [#{field['field_type']}]#{required}"
          end
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "submissions FORM_KEY", "List submissions for an intake form"
      option :project, type: :string, required: true, desc: "Project ID"
      option :status, type: :string, enum: %w[pending approved rejected converted], desc: "Filter by status"
      option :limit, type: :numeric, desc: "Max submissions to return (default: 50)"
      option :since, type: :string, desc: "Only show submissions after this date (ISO 8601)"
      def submissions(form_key)
        ensure_authenticated!
        org = organization
        unless org
          error "Organization required (use --org or set a default with 'kiket configure org')"
          exit 1
        end

        params = {
          organization: org,
          project_id: options[:project],
          status: options[:status],
          limit: options[:limit],
          since: options[:since]
        }.compact

        spinner = spinner("Fetching submissions...")
        spinner.auto_spin

        response = client.get("/api/v1/intake_forms/#{form_key}/submissions", params: params)

        spinner.success("Fetched submissions")

        rows = response.fetch("data", []).map do |sub|
          {
            id: sub["id"],
            status: sub["status"],
            submitted_by: sub.dig("submitted_by", "name") || "Anonymous",
            submitted_at: sub["submitted_at"],
            processed_at: sub["processed_at"] || "-",
            ip_address: sub["ip_address"]
          }
        end

        if rows.empty?
          puts pastel.yellow("No submissions found.")
          return
        end

        headers = %i[id status submitted_by submitted_at processed_at ip_address]
        output_data(rows, headers:)
      rescue StandardError => e
        handle_error(e)
      end

      desc "submission FORM_KEY SUBMISSION_ID", "Show details of a submission"
      option :project, type: :string, required: true, desc: "Project ID"
      def submission(form_key, submission_id)
        ensure_authenticated!
        org = organization
        unless org
          error "Organization required (use --org or set a default with 'kiket configure org')"
          exit 1
        end

        spinner = spinner("Fetching submission...")
        spinner.auto_spin

        response = client.get("/api/v1/intake_forms/#{form_key}/submissions/#{submission_id}", params: {
          organization: org,
          project_id: options[:project]
        })

        spinner.success("Fetched submission")

        sub = response.fetch("data", {})
        data = sub.fetch("data", {})

        puts
        puts pastel.bold("Submission: #{sub['id']}")
        puts "-" * 50
        puts "Status:        #{pastel.send(status_color(sub['status']), sub['status'])}"
        puts "Submitted By:  #{sub.dig('submitted_by', 'name') || 'Anonymous'}"
        puts "Submitted At:  #{sub['submitted_at']}"
        puts "IP Address:    #{sub['ip_address']}"
        puts "User Agent:    #{sub['user_agent']&.truncate(60)}"

        if sub["processed_at"]
          puts "Processed At:  #{sub['processed_at']}"
          puts "Processed By:  #{sub.dig('approved_by', 'name') || '-'}"
        end

        if sub["notes"]
          puts "Notes:         #{sub['notes']}"
        end

        if sub["issue_id"]
          puts
          puts pastel.cyan("Linked Issue: #{sub['issue_id']}")
        end

        if data.any?
          puts
          puts pastel.bold("Form Data:")
          data.each do |key, value|
            formatted_value = value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s
            puts "  #{key}: #{formatted_value.truncate(80)}"
          end
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "approve FORM_KEY SUBMISSION_ID", "Approve a pending submission"
      option :project, type: :string, required: true, desc: "Project ID"
      option :notes, type: :string, desc: "Approval notes"
      def approve(form_key, submission_id)
        ensure_authenticated!
        org = organization
        unless org
          error "Organization required (use --org or set a default with 'kiket configure org')"
          exit 1
        end

        spinner = spinner("Approving submission...")
        spinner.auto_spin

        client.post("/api/v1/intake_forms/#{form_key}/submissions/#{submission_id}/approve", {
          organization: org,
          project_id: options[:project],
          notes: options[:notes]
        }.compact)

        spinner.success("Submission approved")
        success "Submission #{submission_id} has been approved"
      rescue StandardError => e
        handle_error(e)
      end

      desc "reject FORM_KEY SUBMISSION_ID", "Reject a pending submission"
      option :project, type: :string, required: true, desc: "Project ID"
      option :notes, type: :string, desc: "Rejection reason"
      def reject(form_key, submission_id)
        ensure_authenticated!
        org = organization
        unless org
          error "Organization required (use --org or set a default with 'kiket configure org')"
          exit 1
        end

        spinner = spinner("Rejecting submission...")
        spinner.auto_spin

        client.post("/api/v1/intake_forms/#{form_key}/submissions/#{submission_id}/reject", {
          organization: org,
          project_id: options[:project],
          notes: options[:notes]
        }.compact)

        spinner.success("Submission rejected")
        success "Submission #{submission_id} has been rejected"
      rescue StandardError => e
        handle_error(e)
      end

      desc "stats FORM_KEY", "Show statistics for an intake form"
      option :project, type: :string, required: true, desc: "Project ID"
      option :period, type: :string, enum: %w[day week month], desc: "Time period for stats"
      def stats(form_key)
        ensure_authenticated!
        org = organization
        unless org
          error "Organization required (use --org or set a default with 'kiket configure org')"
          exit 1
        end

        params = {
          organization: org,
          project_id: options[:project],
          period: options[:period]
        }.compact

        spinner = spinner("Fetching statistics...")
        spinner.auto_spin

        response = client.get("/api/v1/intake_forms/#{form_key}/stats", params: params)

        spinner.success("Fetched stats")

        stats = response.fetch("data", {})

        puts
        puts pastel.bold("Form Statistics")
        puts "-" * 40
        puts "Total Submissions:   #{stats['total_submissions'] || 0}"
        puts "Pending:             #{pastel.yellow(stats['pending'] || 0)}"
        puts "Approved:            #{pastel.green(stats['approved'] || 0)}"
        puts "Rejected:            #{pastel.red(stats['rejected'] || 0)}"
        puts "Converted:           #{pastel.cyan(stats['converted'] || 0)}"

        if stats["avg_processing_time"]
          puts
          puts "Avg Processing Time: #{stats['avg_processing_time']}"
        end

        if stats["submissions_today"]
          puts
          puts "Today:               #{stats['submissions_today']}"
          puts "This Week:           #{stats['submissions_this_week']}"
          puts "This Month:          #{stats['submissions_this_month']}"
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "usage", "Show intake forms usage for the organization"
      def usage
        ensure_authenticated!
        org = organization
        unless org
          error "Organization required (use --org or set a default with 'kiket configure org')"
          exit 1
        end

        spinner = spinner("Fetching usage info...")
        spinner.auto_spin

        response = client.get("/api/v1/usage/intake_forms", params: { organization: org })

        spinner.success("Fetched usage")

        usage = response.fetch("data", {})

        puts
        puts pastel.bold("Intake Forms Usage")
        puts "-" * 40

        forms = usage["forms"] || {}
        puts "Forms:"
        puts "  Current:  #{forms['current'] || 0}"
        puts "  Limit:    #{forms['limit'] || 'Unlimited'}"
        puts "  Status:   #{pastel.send(usage_status_color(forms['status']), forms['status'] || 'ok')}"

        submissions = usage["submissions"] || {}
        puts
        puts "Monthly Submissions:"
        puts "  Current:  #{submissions['current'] || 0}"
        puts "  Limit:    #{submissions['limit'] || 'Unlimited'}"
        puts "  Status:   #{pastel.send(usage_status_color(submissions['status']), submissions['status'] || 'ok')}"
        puts "  Resets:   #{submissions['resets_at'] || '-'}"
      rescue StandardError => e
        handle_error(e)
      end

      private

      def status_color(status)
        case status&.to_s
        when "pending" then :yellow
        when "approved" then :green
        when "rejected" then :red
        when "converted" then :cyan
        else :white
        end
      end

      def usage_status_color(status)
        case status&.to_s
        when "ok" then :green
        when "approaching" then :yellow
        when "exceeded" then :red
        else :white
        end
      end
    end
  end
end
