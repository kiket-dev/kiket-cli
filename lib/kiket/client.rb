# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "multi_json"

module Kiket
  class Client
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def get(path, params: {}, headers: {})
      request(:get, path, params: params, headers: headers)
    end

    def post(path, body: {}, headers: {})
      request(:post, path, body: body, headers: headers)
    end

    def put(path, body: {}, headers: {})
      request(:put, path, body: body, headers: headers)
    end

    def patch(path, body: {}, headers: {})
      request(:patch, path, body: body, headers: headers)
    end

    def delete(path, headers: {})
      request(:delete, path, headers: headers)
    end

    private

    def request(method, path, params: {}, body: {}, headers: {})
      response = connection.send(method) do |req|
        req.url path
        req.params = params if params.any?
        req.body = MultiJson.dump(body) if body.any?
        req.headers.merge!(headers)
      end

      handle_response(response)
    rescue Faraday::Error => e
      raise APIError, "Network error: #{e.message}"
    end

    def connection
      @connection ||= Faraday.new(url: config.api_base_url) do |conn|
        conn.request :json
        conn.request :retry, max: 3, interval: 0.5, backoff_factor: 2

        conn.response :json, content_type: /\bjson$/
        conn.response :logger if config.verbose

        conn.headers["Authorization"] = "Bearer #{config.api_token}" if config.api_token
        conn.headers["User-Agent"] = "kiket-cli/#{Kiket::VERSION}"
        conn.headers["Accept"] = "application/json"
        conn.headers["Content-Type"] = "application/json"

        conn.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      case response.status
      when 200..299
        response.body
      when 401
        raise UnauthorizedError.new("Unauthorized. Please run 'kiket auth login'", status: response.status, response_body: response.body)
      when 403
        raise ForbiddenError.new("Forbidden. You don't have permission to access this resource", status: response.status, response_body: response.body)
      when 404
        raise NotFoundError.new("Resource not found", status: response.status, response_body: response.body)
      when 429
        raise RateLimitError.new("Rate limit exceeded. Please try again later", status: response.status, response_body: response.body)
      when 500..599
        raise ServerError.new("Server error. Please try again later", status: response.status, response_body: response.body)
      else
        error_message = response.body.is_a?(Hash) ? response.body["error"] || response.body["message"] : "Unknown error"
        raise APIError.new(error_message, status: response.status, response_body: response.body)
      end
    end
  end
end
