# frozen_string_literal: true

module Kiket
  class Error < StandardError; end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  class APIError < Error
    attr_reader :status, :response_body

    def initialize(message, status: nil, response_body: nil)
      super(message)
      @status = status
      @response_body = response_body
    end
  end

  class ValidationError < Error; end
  class NotFoundError < APIError; end
  class UnauthorizedError < APIError; end
  class ForbiddenError < APIError; end
  class RateLimitError < APIError; end
  class ServerError < APIError; end
end
