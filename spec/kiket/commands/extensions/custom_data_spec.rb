# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "kiket/commands/extensions"

RSpec.describe Kiket::Commands::Extensions do
  let(:config) { test_config(output_format: "json") }
  let(:client) { instance_double(Kiket::Client) }

  before do
    Kiket.reset!
    Kiket.instance_variable_set(:@config, config)
    allow(Kiket).to receive(:client).and_return(client)
  end

  after do
    Kiket.reset!
  end

  describe "custom-data:list" do
    it "passes API key header and prints rows" do
      response = { "data" => [{ "id" => 1, "email" => "demo@example.com" }] }
      expect(client).to receive(:get).with(
        "/api/v1/ext/custom_data/com.example/records",
        params: hash_including(project_id: 42, limit: 25),
        headers: hash_including("X-Kiket-API-Key" => "ext_key")
      ).and_return(response)

      output = capture_stdout do
        described_class.start(%w[custom-data:list com.example records --project 42 --limit 25 --api-key ext_key])
      end

      expect(output).to include("demo@example.com")
    end

    it "requires API key" do
      expect {
        described_class.start(%w[custom-data:list com.example records --project 42])
      }.to raise_error(SystemExit)
    end
  end

  def capture_stdout
    original = $stdout
    fake = StringIO.new
    $stdout = fake
    yield
    fake.string
  ensure
    $stdout = original
  end
end
