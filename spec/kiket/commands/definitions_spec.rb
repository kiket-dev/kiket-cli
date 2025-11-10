# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "kiket/commands/definitions"

RSpec.describe Kiket::Commands::Definitions do
  let(:config) { test_config }

  before do
    Kiket.reset!
    Kiket.instance_variable_set(:@config, config)
  end

  after do
    Kiket.reset!
  end

  describe "lint" do
    it "passes for valid definition repo" do
      Dir.mktmpdir do |dir|
        FileUtils.cp_r(File.join(fixtures_path, "definition_repo", "valid", "."), dir)

        output = capture_stdout do
          described_class.start(["lint", dir, "--skip-dbt-cli"])
        end

        expect(output).to include("Workflow lint passed")
        expect(output).to include("Dashboard lint passed")
        expect(output).to include("dbt lint passed")
      end
    end

    it "fails fast when errors are detected" do
      Dir.mktmpdir do |dir|
        FileUtils.cp_r(File.join(fixtures_path, "definition_repo", "invalid", "."), dir)

        expect do
          described_class.start(["lint", dir, "--fail-fast", "--dashboards", "false", "--dbt", "false"])
        end.to raise_error(SystemExit)
      end
    end
  end

  def fixtures_path
    File.expand_path("../../fixtures", __dir__)
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
