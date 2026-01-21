# frozen_string_literal: true

require "thor"
require "tty-prompt"
require "tty-spinner"
require "tty-table"
require "pastel"
require "active_support/core_ext/module/delegation"

module Kiket
  module Commands
    class Base < Thor
      def self.exit_on_failure?
        true
      end

      no_commands do
        delegate :config, to: :Kiket

        delegate :client, to: :Kiket

        def prompt
          @prompt ||= TTY::Prompt.new
        end

        def pastel
          @pastel ||= Pastel.new
        end

        def spinner(message)
          TTY::Spinner.new("[:spinner] #{message}", format: :dots)
        end

        def ensure_authenticated!
          return if config.authenticated?

          error "Not authenticated. Please run 'kiket auth login' first"
          exit 1
        end

        def output_format
          options[:format] || config.output_format || "human"
        end

        def verbose?
          options[:verbose] || config.verbose
        end

        def organization
          options[:org] || config.default_org
        end

        def success(message)
          puts pastel.green("✓ #{message}")
        end

        def error(message)
          puts pastel.red("✗ #{message}")
        end

        def warning(message)
          puts pastel.yellow("⚠ #{message}")
        end

        def info(message)
          puts pastel.blue("ℹ #{message}")
        end

        def output_data(data, headers: nil)
          case output_format
          when "json"
            output_json(data)
          when "csv"
            output_csv(data, headers: headers)
          else
            output_table(data, headers: headers)
          end
        end

        def output_json(data)
          require "multi_json"
          puts MultiJson.dump(data, pretty: true)
        end

        def output_csv(data, headers:)
          require "csv"
          return if data.empty?

          rows = data.is_a?(Array) ? data : [data]
          headers ||= rows.first.keys

          CSV.generate do |csv|
            csv << headers
            rows.each do |row|
              csv << headers.map { |h| row[h] }
            end
          end
        end

        def output_table(data, headers:)
          return puts "No data" if data.empty?

          rows = data.is_a?(Array) ? data : [data]
          headers ||= rows.first.keys

          table = TTY::Table.new(headers, rows.map { |row| headers.map { |h| row[h] } })
          puts table.render(:unicode, padding: [0, 1])
        end

        def handle_error(error)
          case error
          when Kiket::UnauthorizedError
            error "Authentication failed: #{error.message}"
            info "Run 'kiket auth login' to authenticate"
          when Kiket::ValidationError
            error "Validation error: #{error.message}"
          when Kiket::NotFoundError
            error "Not found: #{error.message}"
          when Kiket::APIError
            error "API error: #{error.message}"
            puts "  Status: #{error.status}" if error.status
            puts "  Response: #{error.response_body}" if verbose? && error.response_body
          else
            error "Unexpected error: #{error.message}"
            puts error.backtrace.join("\n") if verbose?
          end
          exit 1
        end

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end

        def present?(value)
          !blank?(value)
        end
      end

      protected :config, :client, :prompt, :pastel, :spinner, :ensure_authenticated!, :output_format,
                :verbose?, :organization, :success, :error, :warning, :info, :output_data, :output_json,
                :output_csv, :output_table, :handle_error, :blank?, :present?
    end
  end
end
