# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Connections < Base
      desc "list", "List OAuth connections for the current user"
      option :status, type: :string, enum: %w[active expired all], desc: "Filter by connection status"
      def list
        ensure_authenticated!

        spinner = spinner("Loading OAuth connections...")
        spinner.auto_spin

        params = {}
        params[:status] = options[:status] if options[:status]

        response = client.get("/api/v1/oauth/connections", params: params)
        connections = response.fetch("connections", [])

        spinner.stop

        if connections.empty?
          info "No OAuth connections found"
          info "Connect to external services via Settings > Connected Accounts in Kiket"
          return
        end

        output_connections(connections)
      rescue StandardError => e
        handle_error(e)
      end

      desc "show CONNECTION_ID", "Show details of an OAuth connection"
      def show(connection_id)
        ensure_authenticated!

        spinner = spinner("Loading connection details...")
        spinner.auto_spin

        response = client.get("/api/v1/oauth/connections/#{connection_id}")
        connection = response.fetch("connection")

        spinner.stop

        output_connection_details(connection)
      rescue StandardError => e
        handle_error(e)
      end

      desc "disconnect CONNECTION_ID", "Disconnect an OAuth connection"
      option :force, type: :boolean, default: false, desc: "Skip confirmation"
      def disconnect(connection_id)
        ensure_authenticated!

        # Load connection details first
        response = client.get("/api/v1/oauth/connections/#{connection_id}")
        connection = response.fetch("connection")

        provider_name = connection["provider_name"] || connection["provider_id"]
        consumers = connection["consumer_extensions"] || []

        unless options[:force]
          puts pastel.bold("\nDisconnect OAuth Connection")
          puts "  Provider: #{provider_name}"
          puts "  Account: #{connection["external_email"]}"

          if consumers.any?
            puts ""
            warning "This will affect #{consumers.length} extension(s):"
            consumers.each do |ext|
              puts "    - #{ext["name"] || ext["id"]}"
            end
          end

          puts ""
          return unless prompt.yes?("Are you sure you want to disconnect?")
        end

        spinner = spinner("Disconnecting...")
        spinner.auto_spin

        client.post("/api/v1/oauth/connections/#{connection_id}/disconnect")

        spinner.success("Disconnected")
        success "OAuth connection to #{provider_name} has been disconnected"
      rescue StandardError => e
        handle_error(e)
      end

      desc "refresh CONNECTION_ID", "Refresh an OAuth connection token"
      def refresh(connection_id)
        ensure_authenticated!

        spinner = spinner("Refreshing token...")
        spinner.auto_spin

        response = client.post("/api/v1/oauth/connections/#{connection_id}/refresh")
        connection = response.fetch("connection")

        spinner.success("Refreshed")

        status = connection["status"]
        if status == "active"
          success "Token refreshed successfully"
          info "New expiry: #{connection["expires_at"]}" if connection["expires_at"]
        else
          warning "Token status: #{status}"
          info "You may need to reconnect this account"
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "providers", "List available OAuth providers"
      def providers
        ensure_authenticated!

        spinner = spinner("Loading OAuth providers...")
        spinner.auto_spin

        response = client.get("/api/v1/oauth/providers")
        providers = response.fetch("providers", [])

        spinner.stop

        if providers.empty?
          info "No OAuth providers installed"
          info "Install OAuth provider extensions from the marketplace"
          return
        end

        output_providers(providers)
      rescue StandardError => e
        handle_error(e)
      end

      desc "provider PROVIDER_ID", "Show details of an OAuth provider"
      def provider(provider_id)
        ensure_authenticated!

        spinner = spinner("Loading provider details...")
        spinner.auto_spin

        response = client.get("/api/v1/oauth/providers/#{provider_id}")
        provider = response.fetch("provider")

        spinner.stop

        output_provider_details(provider)
      rescue StandardError => e
        handle_error(e)
      end

      private

      def output_connections(connections)
        case output_format
        when "json"
          output_json(connections)
        else
          puts pastel.bold("\nOAuth Connections\n")

          connections.each do |conn|
            status_color = case conn["status"]
                           when "active" then :green
                           when "expired" then :red
                           else :yellow
                           end

            status_icon = case conn["status"]
                          when "active" then "✓"
                          when "expired" then "✗"
                          else "?"
                          end

            puts pastel.send(status_color, "#{status_icon} #{conn["provider_name"] || conn["provider_id"]}")
            puts "    ID: #{conn["id"]}"
            puts "    Account: #{conn["external_email"]}" if conn["external_email"]
            puts "    Status: #{conn["status"]}"
            puts "    Connected: #{format_time(conn["connected_at"])}" if conn["connected_at"]

            consumers = conn["consumer_extensions"] || []
            puts "    Used by: #{consumers.map { |c| c["name"] || c["id"] }.join(", ")}" if consumers.any?

            puts ""
          end
        end
      end

      def output_connection_details(connection)
        case output_format
        when "json"
          output_json(connection)
        else
          status_color = connection["status"] == "active" ? :green : :red

          puts pastel.bold("\nOAuth Connection Details\n")
          puts "  ID: #{connection["id"]}"
          puts "  Provider: #{connection["provider_name"] || connection["provider_id"]}"
          puts "  Account: #{connection["external_email"]}" if connection["external_email"]
          puts "  Status: #{pastel.send(status_color, connection["status"])}"
          puts "  Connected: #{format_time(connection["connected_at"])}" if connection["connected_at"]
          puts "  Expires: #{format_time(connection["expires_at"])}" if connection["expires_at"]

          scopes = connection["granted_scopes"] || []
          if scopes.any?
            puts ""
            puts pastel.bold("  Granted Scopes:")
            scopes.each do |scope|
              puts "    - #{scope}"
            end
          end

          consumers = connection["consumer_extensions"] || []
          if consumers.any?
            puts ""
            puts pastel.bold("  Consumer Extensions:")
            consumers.each do |ext|
              puts "    - #{ext["name"] || ext["id"]}"
            end
          end

          puts ""
        end
      end

      def output_providers(providers)
        case output_format
        when "json"
          output_json(providers)
        else
          puts pastel.bold("\nOAuth Providers\n")

          providers.each do |prov|
            connected_icon = prov["connected"] ? pastel.green("✓") : "○"
            installed_badge = prov["installed"] ? "" : pastel.dim(" (not installed)")

            puts "#{connected_icon} #{prov["name"] || prov["id"]}#{installed_badge}"
            puts "    ID: #{prov["id"]}"

            required_by = prov["required_by"] || []
            puts "    Required by: #{required_by.join(", ")}" if required_by.any?

            puts ""
          end

          puts pastel.dim("Legend: ✓ = connected, ○ = not connected")
          puts ""
        end
      end

      def output_provider_details(provider)
        case output_format
        when "json"
          output_json(provider)
        else
          puts pastel.bold("\nOAuth Provider Details\n")
          puts "  ID: #{provider["id"]}"
          puts "  Name: #{provider["name"]}"
          puts "  Installed: #{provider["installed"] ? "Yes" : "No"}"
          puts "  Connected: #{provider["connected"] ? "Yes" : "No"}"

          required_by = provider["required_by"] || []
          if required_by.any?
            puts ""
            puts pastel.bold("  Required by Extensions:")
            required_by.each do |ext_id|
              puts "    - #{ext_id}"
            end
          end

          available_scopes = provider["available_scopes"] || []
          if available_scopes.any?
            puts ""
            puts pastel.bold("  Available Scopes:")
            available_scopes.each do |scope|
              if scope.is_a?(Hash)
                puts "    - #{scope["id"]}: #{scope["description"]}"
              else
                puts "    - #{scope}"
              end
            end
          end

          puts ""
        end
      end

      def format_time(time_str)
        return nil unless time_str

        Time.parse(time_str).strftime("%Y-%m-%d %H:%M:%S")
      rescue StandardError
        time_str
      end
    end
  end
end
