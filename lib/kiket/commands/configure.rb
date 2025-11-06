# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Configure < Base
      desc "set KEY VALUE", "Set a configuration value"
      def set(key, value)
        case key
        when "api_url", "api_base_url"
          config.api_base_url = value
        when "default_org", "org"
          config.default_org = value
        when "output_format", "format"
          unless %w[human json csv].include?(value)
            error "Invalid format. Must be one of: human, json, csv"
            exit 1
          end
          config.output_format = value
        when "verbose"
          config.verbose = %w[true yes 1].include?(value.downcase)
        else
          error "Unknown configuration key: #{key}"
          exit 1
        end

        config.save
        success "Configuration updated: #{key} = #{value}"
      rescue StandardError => e
        handle_error(e)
      end

      desc "get KEY", "Get a configuration value"
      def get(key)
        value = case key
                when "api_url", "api_base_url"
                  config.api_base_url
                when "default_org", "org"
                  config.default_org
                when "output_format", "format"
                  config.output_format
                when "verbose"
                  config.verbose
                else
                  error "Unknown configuration key: #{key}"
                  exit 1
                end

        puts value || "(not set)"
      rescue StandardError => e
        handle_error(e)
      end

      desc "list", "List all configuration values"
      def list
        puts "Current configuration:"
        puts "  API URL: #{config.api_base_url || '(not set)'}"
        puts "  Default org: #{config.default_org || '(not set)'}"
        puts "  Output format: #{config.output_format}"
        puts "  Verbose: #{config.verbose}"
        puts "  Token: #{config.authenticated? ? '[set]' : '(not set)'}"
        puts ""
        puts "Config file: #{Config::CONFIG_FILE}"
      rescue StandardError => e
        handle_error(e)
      end

      desc "reset", "Reset configuration to defaults"
      def reset
        if prompt.yes?("Reset all configuration? This will remove your API token.")
          config.api_base_url = "https://app.kiket.ai"
          config.api_token = nil
          config.default_org = nil
          config.output_format = "human"
          config.verbose = false
          config.save
          success "Configuration reset to defaults"
        end
      rescue StandardError => e
        handle_error(e)
      end
    end
  end
end
