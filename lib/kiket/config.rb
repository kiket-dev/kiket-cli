# frozen_string_literal: true

require "yaml"
require "fileutils"

module Kiket
  class Config
    CONFIG_DIR = File.expand_path("~/.kiket").freeze
    CONFIG_FILE = File.join(CONFIG_DIR, "config").freeze

    attr_accessor :api_base_url, :api_token, :default_org, :output_format, :verbose

    def initialize(attributes = {})
      @api_base_url = attributes[:api_base_url] || ENV["KIKET_API_URL"] || "https://kiket.dev"
      @api_token = attributes[:api_token] || ENV.fetch("KIKET_API_TOKEN", nil)
      @default_org = attributes[:default_org] || ENV.fetch("KIKET_DEFAULT_ORG", nil)
      @output_format = attributes[:output_format] || "human"
      @verbose = attributes[:verbose] || false
    end

    def self.load
      if File.exist?(CONFIG_FILE)
        data = YAML.load_file(CONFIG_FILE) || {}
        new(symbolize_keys(data))
      else
        new
      end
    end

    def save
      FileUtils.mkdir_p(CONFIG_DIR)
      File.write(CONFIG_FILE, to_yaml)
      File.chmod(0o600, CONFIG_FILE) # Protect config file
    end

    def to_yaml
      YAML.dump(to_h.transform_keys(&:to_s))
    end

    def to_h
      {
        api_base_url: api_base_url,
        api_token: api_token,
        default_org: default_org,
        output_format: output_format,
        verbose: verbose
      }
    end

    def authenticated?
      api_token.present?
    end

    def self.symbolize_keys(hash)
      hash.transform_keys(&:to_sym)
    end
  end
end
