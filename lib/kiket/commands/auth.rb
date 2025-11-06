# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Auth < Base
      desc "login", "Authenticate with Kiket"
      option :token, type: :string, desc: "API token (will prompt if not provided)"
      option :api_url, type: :string, desc: "API base URL"
      def login
        api_url = options[:api_url] || config.api_base_url || prompt.ask("API URL:", default: "https://kiket.dev")
        token = options[:token] || prompt.mask("API Token:")

        if token.nil? || token.empty?
          error "Token is required"
          exit 1
        end

        # Test authentication
        temp_config = Config.new(api_base_url: api_url, api_token: token)
        temp_client = Client.new(temp_config)

        spinner = spinner("Verifying credentials...")
        spinner.auto_spin

        begin
          response = temp_client.get("/api/v1/me")
          spinner.success("Authenticated!")

          config.api_base_url = api_url
          config.api_token = token
          config.default_org = response["organization"]["slug"] if response["organization"]
          config.save

          success "Logged in successfully"
          info "Organization: #{response["organization"]["name"]}" if response["organization"]
          info "User: #{response["email"]}" if response["email"]
        rescue APIError => e
          spinner.error("Authentication failed")
          handle_error(e)
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "logout", "Remove stored credentials"
      def logout
        config.api_token = nil
        config.save
        success "Logged out successfully"
      rescue StandardError => e
        handle_error(e)
      end

      desc "status", "Show authentication status"
      def status
        if config.authenticated?
          success "Authenticated"
          info "API URL: #{config.api_base_url}"
          info "Default organization: #{config.default_org}" if config.default_org

          begin
            response = client.get("/api/v1/me")
            info "User: #{response["email"]}" if response["email"]
            info "Organization: #{response["organization"]["name"]}" if response["organization"]
          rescue APIError
            warning "Token may be invalid or expired"
          end
        else
          warning "Not authenticated"
          info "Run 'kiket auth login' to authenticate"
        end
      rescue StandardError => e
        handle_error(e)
      end

      desc "token", "Display current API token"
      def token
        if config.authenticated?
          puts config.api_token if prompt.yes?("Show API token? (Will be visible on screen)")
        else
          warning "Not authenticated"
        end
      rescue StandardError => e
        handle_error(e)
      end
    end
  end
end
