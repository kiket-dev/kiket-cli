# frozen_string_literal: true

require_relative "kiket/version"
require_relative "kiket/config"
require_relative "kiket/client"
require_relative "kiket/errors"

module Kiket
  class << self
    def config
      @config ||= Config.load
    end

    def client
      @client ||= Client.new(config)
    end

    def reset!
      @config = nil
      @client = nil
    end
  end
end
