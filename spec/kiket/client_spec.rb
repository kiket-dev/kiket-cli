# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kiket::Client do
  let(:config) { test_config }
  let(:client) { described_class.new(config) }

  describe "#get" do
    it "makes GET request with auth headers" do
      stub = stub_api_request(:get, "/api/v1/test", response: { data: "test" })

      response = client.get("/api/v1/test")

      expect(response).to eq({ "data" => "test" })
      expect(stub).to have_been_requested
    end

    it "includes query parameters" do
      stub = stub_api_request(:get, "/api/v1/test?foo=bar", response: { data: "test" })

      client.get("/api/v1/test", params: { foo: "bar" })

      expect(stub).to have_been_requested
    end

    it "raises UnauthorizedError on 401" do
      stub_api_request(:get, "/api/v1/test", status: 401, response: { error: "Unauthorized" })

      expect {
        client.get("/api/v1/test")
      }.to raise_error(Kiket::UnauthorizedError, /Unauthorized/)
    end

    it "raises NotFoundError on 404" do
      stub_api_request(:get, "/api/v1/test", status: 404, response: { error: "Not found" })

      expect {
        client.get("/api/v1/test")
      }.to raise_error(Kiket::NotFoundError, /not found/)
    end

    it "raises RateLimitError on 429" do
      stub_api_request(:get, "/api/v1/test", status: 429, response: { error: "Rate limited" })

      expect {
        client.get("/api/v1/test")
      }.to raise_error(Kiket::RateLimitError, /Rate limit/)
    end

    it "raises ServerError on 500" do
      stub_api_request(:get, "/api/v1/test", status: 500, response: { error: "Server error" })

      expect {
        client.get("/api/v1/test")
      }.to raise_error(Kiket::ServerError, /Server error/)
    end
  end

  describe "#post" do
    it "makes POST request with body" do
      stub = stub_api_request(
        :post,
        "/api/v1/test",
        response: { created: true }
      )

      response = client.post("/api/v1/test", body: { name: "test" })

      expect(response).to eq({ "created" => true })
      expect(stub).to have_been_requested
    end
  end

  describe "#put" do
    it "makes PUT request" do
      stub = stub_api_request(
        :put,
        "/api/v1/test/123",
        response: { updated: true }
      )

      response = client.put("/api/v1/test/123", body: { name: "updated" })

      expect(response).to eq({ "updated" => true })
      expect(stub).to have_been_requested
    end
  end

  describe "#delete" do
    it "makes DELETE request" do
      stub = stub_api_request(:delete, "/api/v1/test/123", response: {})

      client.delete("/api/v1/test/123")

      expect(stub).to have_been_requested
    end
  end
end
