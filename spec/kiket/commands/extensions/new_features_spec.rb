# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "kiket/commands/extensions"

RSpec.describe Kiket::Commands::Extensions do
  let(:config) { test_config(default_org: "acme") }
  let(:client) { instance_double(Kiket::Client) }

  before do
    Kiket.reset!
    Kiket.instance_variable_set(:@config, config)
    allow(Kiket).to receive(:client).and_return(client)
  end

  after do
    Kiket.reset!
  end

  describe "#replay" do
    let(:response) { instance_double(Net::HTTPResponse, code: "200", body: '{"status":"allow"}') }

    it "posts payload to target url" do
      file = Tempfile.new("payload")
      file.write({ event: "workflow.before_transition" }.to_json)
      file.close

      received = nil
      allow_any_instance_of(described_class).to receive(:perform_replay_request) do |_instance, _url, _method, body, _headers|
        received = JSON.parse(body)
        response
      end

      described_class.start(["replay", "--payload", file.path, "--url", "http://localhost:9999/webhook"])
      expect(received["event"]).to eq("workflow.before_transition")
    ensure
      file.unlink
    end

    it "injects secrets from env file and prefix" do
      ENV["KIKET_SECRET_GLOBAL_TOKEN"] = "env-secret"
      env = Tempfile.new(".env")
      env.write("LOCAL_KEY=local-secret\n")
      env.close

      allow_any_instance_of(described_class).to receive(:perform_replay_request) do |_instance, _url, _method, body, _headers|
        payload = JSON.parse(body)
        expect(payload["secrets"]).to include("LOCAL_KEY" => "local-secret", "GLOBAL_TOKEN" => "env-secret")
        response
      end

      described_class.start([
                              "replay",
                              "--template", "before_transition",
                              "--env-file", env.path,
                              "--url", "http://localhost:8080/webhook"
                            ])
    ensure
      env.unlink
      ENV.delete("KIKET_SECRET_GLOBAL_TOKEN")
    end
  end

  describe "extension secrets sync" do
    it "pulls secrets into env file" do
      tmp_dir = Dir.mktmpdir
      env_path = File.join(tmp_dir, ".env.pull")

      expect(client).to receive(:get).with("/api/v1/extensions/com.example/slack/secrets")
                                     .and_return([{ "key" => "API_TOKEN" }])
      expect(client).to receive(:get).with("/api/v1/extensions/com.example/slack/secrets/API_TOKEN")
                                     .and_return({ "key" => "API_TOKEN", "value" => "abc123" })

      described_class.start(["secrets:pull", "com.example/slack", "--output", env_path])

      contents = File.read(env_path)
      expect(contents).to include("API_TOKEN=abc123")
    ensure
      FileUtils.remove_entry(tmp_dir, true)
    end

    it "pushes secrets from env file" do
      tmp = Tempfile.new(".env")
      tmp.write("API_TOKEN=xyz\n")
      tmp.close

      expect(client).to receive(:post).with("/api/v1/extensions/com.example/slack/secrets",
                                            body: { secret: { key: "API_TOKEN", value: "xyz" } })

      described_class.start(["secrets:push", "com.example/slack", "--env-file", tmp.path])
    ensure
      tmp.unlink
    end
  end

  describe "#test runner detection" do
    let(:tmp_dir) { Dir.mktmpdir }

    after do
      FileUtils.remove_entry(tmp_dir, true) if tmp_dir && Dir.exist?(tmp_dir)
    end

    it "runs pytest via poetry when poetry files are present" do
      File.write(File.join(tmp_dir, "poetry.lock"), "")
      File.write(File.join(tmp_dir, "pyproject.toml"), "[tool.poetry]\nname = \"sample\"")

      allow_any_instance_of(described_class).to receive(:command_available?).and_return(false)
      expect_any_instance_of(described_class).to receive(:run_shell).with(/poetry run pytest/).and_return(true)

      described_class.start(["test", tmp_dir])
    end

    it "runs npm test with watch flag when package.json exists" do
      File.write(File.join(tmp_dir, "package.json"), { name: "sample", scripts: { test: "jest" } }.to_json)
      File.write(File.join(tmp_dir, "package-lock.json"), "")

      expect_any_instance_of(described_class).to receive(:run_shell).with(/npm test -- --watch/).and_return(true)

      described_class.start(["test", tmp_dir, "--watch"])
    end
  end
end
