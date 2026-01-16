# frozen_string_literal: true

require_relative "lib/kiket/version"

Gem::Specification.new do |spec|
  spec.name = "kiket-cli"
  spec.version = Kiket::VERSION
  spec.authors = ["Kiket Team"]
  spec.email = ["team@kiket.dev"]

  spec.summary = "Official CLI for Kiket workflow automation platform"
  spec.description = "Command-line interface for managing Kiket marketplace products, extensions, " \
                     "workflows, and secrets"
  spec.homepage = "https://kiket.dev"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kiket/kiket-cli"
  spec.metadata["changelog_uri"] = "https://github.com/kiket/kiket-cli/blob/main/CHANGELOG.md"
  spec.metadata["github_repo"] = "ssh://github.com/kiket/kiket-cli"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob("{bin,lib,exe}/**/*") + %w[LICENSE README.md]
  spec.bindir = "bin"
  spec.executables = ["kiket"]
  spec.require_paths = ["lib"]

  # CLI framework
  spec.add_dependency "thor", "~> 1.3"

  # HTTP client
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-retry", "~> 2.0"

  # JSON parsing
  spec.add_dependency "multi_json", "~> 1.15"

  # Terminal output
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "tty-prompt", "~> 0.23"
  spec.add_dependency "tty-spinner", "~> 0.9"
  spec.add_dependency "tty-table", "~> 0.12"

  # Development dependencies
  spec.add_development_dependency "pry", "~> 0.14"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop", "~> 1.80"
  spec.add_development_dependency "rubocop-rspec", "~> 3.0"
  spec.add_development_dependency "vcr", "~> 6.1"
  spec.add_development_dependency "webmock", "~> 3.18"
end
