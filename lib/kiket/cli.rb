# frozen_string_literal: true

require "thor"
require_relative "commands/auth"
require_relative "commands/configure"
require_relative "commands/marketplace"
require_relative "commands/extensions"
require_relative "commands/workflows"
require_relative "commands/definitions"
require_relative "commands/secrets"
require_relative "commands/analytics"
require_relative "commands/agents"
require_relative "commands/sandbox"
require_relative "commands/doctor"
require_relative "commands/sla"
require_relative "commands/milestones"
require_relative "commands/issues"
require_relative "commands/intakes"
require_relative "commands/audit"
require_relative "commands/connections"
require_relative "commands/projects"
require_relative "commands/workflow_repos"
require_relative "commands/sync"

module Kiket
  class CLI < Thor
    class_option :verbose, type: :boolean, aliases: "-v", desc: "Enable verbose output"
    class_option :format, type: :string, enum: %w[human json csv], desc: "Output format"
    class_option :org, type: :string, desc: "Organization slug or ID"

    def self.exit_on_failure?
      true
    end

    desc "auth SUBCOMMAND ...ARGS", "Authentication commands"
    subcommand "auth", Commands::Auth

    desc "configure SUBCOMMAND ...ARGS", "Configuration management"
    subcommand "configure", Commands::Configure

    desc "marketplace SUBCOMMAND ...ARGS", "Marketplace product lifecycle management"
    subcommand "marketplace", Commands::Marketplace

    desc "extensions SUBCOMMAND ...ARGS", "Extension development and testing"
    subcommand "extensions", Commands::Extensions

    desc "workflows SUBCOMMAND ...ARGS", "Workflow validation and testing"
    subcommand "workflows", Commands::Workflows

    desc "definitions SUBCOMMAND ...ARGS", "Definition repository testing"
    subcommand "definitions", Commands::Definitions

    desc "secrets SUBCOMMAND ...ARGS", "Secret provisioning and rotation"
    subcommand "secrets", Commands::Secrets

    desc "analytics SUBCOMMAND ...ARGS", "Telemetry and reporting"
    subcommand "analytics", Commands::Analytics

    desc "agents SUBCOMMAND ...ARGS", "Agent definition utilities"
    subcommand "agents", Commands::Agents

    desc "sandbox SUBCOMMAND ...ARGS", "Demo environment management"
    subcommand "sandbox", Commands::Sandbox

    desc "sla SUBCOMMAND ...ARGS", "SLA monitoring utilities"
    subcommand "sla", Commands::Sla

    desc "milestones SUBCOMMAND ...ARGS", "Milestone management"
    subcommand "milestones", Commands::Milestones

    desc "issues SUBCOMMAND ...ARGS", "Issue management"
    subcommand "issues", Commands::Issues

    desc "intakes SUBCOMMAND ...ARGS", "Intake forms management"
    subcommand "intakes", Commands::Intakes

    desc "audit SUBCOMMAND ...ARGS", "Blockchain audit verification"
    subcommand "audit", Commands::Audit

    desc "connections SUBCOMMAND ...ARGS", "OAuth connections management"
    subcommand "connections", Commands::Connections

    desc "project SUBCOMMAND ...ARGS", "Project management"
    subcommand "project", Commands::Projects

    desc "workflow-repo SUBCOMMAND ...ARGS", "Workflow repository management"
    subcommand "workflow-repo", Commands::WorkflowRepos

    desc "sync SUBCOMMAND ...ARGS", "Trigger configuration sync"
    subcommand "sync", Commands::Sync

    desc "doctor", "Run diagnostic health checks"
    subcommand "doctor", Commands::Doctor

    desc "version", "Show CLI version"
    def version
      puts("kiket-cli version #{Kiket::VERSION}")
    end
  end
end
