# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

task default: %i[spec rubocop]

desc "Run console with CLI loaded"
task :console do
  require "pry"
  require_relative "lib/kiket"
  Pry.start
end

desc "Install CLI locally"
task :install_local do
  sh "gem build kiket-cli.gemspec"
  sh "gem install ./kiket-cli-*.gem"
  sh "rm kiket-cli-*.gem"
end
