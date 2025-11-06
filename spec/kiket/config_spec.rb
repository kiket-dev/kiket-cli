# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kiket::Config do
  describe "#initialize" do
    it "sets default values" do
      config = described_class.new
      expect(config.api_base_url).to eq("https://app.kiket.ai")
      expect(config.output_format).to eq("human")
      expect(config.verbose).to be false
    end

    it "accepts override values" do
      config = described_class.new(
        api_base_url: "https://custom.kiket.ai",
        api_token: "custom-token",
        verbose: true
      )

      expect(config.api_base_url).to eq("https://custom.kiket.ai")
      expect(config.api_token).to eq("custom-token")
      expect(config.verbose).to be true
    end

    it "uses environment variables when available" do
      allow(ENV).to receive(:[]).with("KIKET_API_URL").and_return("https://env.kiket.ai")
      allow(ENV).to receive(:[]).with("KIKET_API_TOKEN").and_return("env-token")
      allow(ENV).to receive(:[]).with("KIKET_DEFAULT_ORG").and_return("env-org")

      config = described_class.new

      expect(config.api_base_url).to eq("https://env.kiket.ai")
      expect(config.api_token).to eq("env-token")
      expect(config.default_org).to eq("env-org")
    end
  end

  describe "#authenticated?" do
    it "returns true when token is set" do
      config = described_class.new(api_token: "some-token")
      expect(config.authenticated?).to be true
    end

    it "returns false when token is nil" do
      config = described_class.new(api_token: nil)
      expect(config.authenticated?).to be false
    end

    it "returns false when token is empty" do
      config = described_class.new(api_token: "")
      expect(config.authenticated?).to be false
    end
  end

  describe "#to_h" do
    it "returns config as hash" do
      config = described_class.new(
        api_base_url: "https://test.kiket.ai",
        api_token: "test-token"
      )

      hash = config.to_h

      expect(hash[:api_base_url]).to eq("https://test.kiket.ai")
      expect(hash[:api_token]).to eq("test-token")
      expect(hash[:output_format]).to eq("human")
    end
  end
end
