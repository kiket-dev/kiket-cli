# frozen_string_literal: true

require_relative "base"

module Kiket
  module Commands
    class Secrets < Base
      desc "init", "Initialize secrets for organization/product"
      option :product, type: :string, desc: "Product installation ID"
      def init
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        scope = {
          organization: org,
          product_installation: options[:product]
        }

        spinner = spinner("Initializing secrets...")
        spinner.auto_spin

        response = client.post("/api/v1/secrets/init", body: scope)

        spinner.success("Secrets initialized")
        success "Secret store created for #{org}"
        info "Secrets: #{response["secret_count"]} initialized" if response["secret_count"]
      rescue StandardError => e
        handle_error(e)
      end

      desc "set KEY VALUE", "Set a secret value"
      option :product, type: :string, desc: "Product installation ID"
      def set(key, value = nil)
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        # Prompt for value if not provided (for sensitive data)
        value ||= prompt.mask("Secret value for #{key}:")

        if value.nil? || value.empty?
          error "Value is required"
          exit 1
        end

        scope = {
          organization: org,
          product_installation: options[:product]
        }

        spinner = spinner("Setting secret...")
        spinner.auto_spin

        client.put("/api/v1/secrets/#{key}",
                   body: scope.merge(value: value))

        spinner.success
        success "Secret '#{key}' set successfully"
      rescue StandardError => e
        handle_error(e)
      end

      desc "rotate KEY", "Rotate a secret value"
      option :product, type: :string, desc: "Product installation ID"
      def rotate(key)
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        new_value = prompt.mask("New secret value for #{key}:")

        if new_value.nil? || new_value.empty?
          error "Value is required"
          exit 1
        end

        scope = {
          organization: org,
          product_installation: options[:product]
        }

        spinner = spinner("Rotating secret...")
        spinner.auto_spin

        client.post("/api/v1/secrets/#{key}/rotate",
                    body: scope.merge(value: new_value))

        spinner.success
        success "Secret '#{key}' rotated successfully"
      rescue StandardError => e
        handle_error(e)
      end

      desc "list", "List all secrets"
      option :product, type: :string, desc: "Product installation ID"
      def list
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        params = { organization: org }
        params[:product_installation] = options[:product] if options[:product]

        response = client.get("/api/v1/secrets", params: params.merge(include_values: true))

        secrets = response["secrets"].map do |secret|
          {
            key: secret["key"],
            created: secret["created_at"],
            updated: secret["updated_at"],
            rotations: secret["rotation_count"] || 0
          }
        end

        output_data(secrets, headers: %i[key created updated rotations])
      rescue StandardError => e
        handle_error(e)
      end

      desc "export", "Export secrets to file"
      option :product, type: :string, desc: "Product installation ID"
      option :output, type: :string, default: ".env", desc: "Output file path"
      def export
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        params = { organization: org }
        params[:product_installation] = options[:product] if options[:product]

        response = client.get("/api/v1/secrets", params: params)

        File.open(options[:output], "w") do |file|
          file.puts "# Kiket secrets for #{org}"
          file.puts "# Generated: #{Time.now}"
          file.puts ""

          response["secrets"].each do |secret|
            file.puts "#{secret["key"]}=#{secret["value"]}"
          end
        end

        success "Secrets exported to #{options[:output]}"
        warning "Keep this file secure and never commit it to version control"
      rescue StandardError => e
        handle_error(e)
      end

      desc "sync-from-env", "Sync secrets from environment variables"
      option :prefix, type: :string, default: "KIKET_SECRET_", desc: "Environment variable prefix"
      option :product, type: :string, desc: "Product installation ID"
      def sync_from_env
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        prefix = options[:prefix]
        env_secrets = ENV.select { |k, _v| k.start_with?(prefix) }

        if env_secrets.empty?
          warning "No environment variables found with prefix '#{prefix}'"
          return
        end

        info "Found #{env_secrets.size} secrets to sync"

        scope = {
          organization: org,
          product_installation: options[:product]
        }

        synced = 0
        env_secrets.each do |key, value|
          secret_key = key.sub(prefix, "").downcase

          begin
            client.put("/api/v1/secrets/#{secret_key}",
                       body: scope.merge(value: value))
            synced += 1
            success "Synced: #{secret_key}" if verbose?
          rescue StandardError => e
            error "Failed to sync #{secret_key}: #{e.message}"
          end
        end

        success "Synced #{synced}/#{env_secrets.size} secrets"
      rescue StandardError => e
        handle_error(e)
      end

      desc "delete KEY", "Delete a secret"
      option :product, type: :string, desc: "Product installation ID"
      option :force, type: :boolean, desc: "Skip confirmation"
      def delete(key)
        ensure_authenticated!
        org = organization

        unless org
          error "Organization required"
          exit 1
        end

        return if !options[:force] && !prompt.yes?("Delete secret '#{key}'?")

        scope = {
          organization: org,
          product_installation: options[:product]
        }

        client.request(:delete, "/api/v1/secrets/#{key}", body: scope)

        success "Secret '#{key}' deleted"
      rescue StandardError => e
        handle_error(e)
      end
    end
  end
end
