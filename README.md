# Kiket CLI

Official command-line interface for the Kiket workflow automation platform.

## Installation

### From RubyGems (Coming Soon)

```bash
gem install kiket-cli
```

### From GitHub Packages

```bash
# Configure GitHub Packages as a gem source
gem sources --add https://rubygems.pkg.github.com/kiket

# Create ~/.gem/credentials with your GitHub token
# (Only needed once)
echo ":github: Bearer YOUR_GITHUB_TOKEN" >> ~/.gem/credentials
chmod 0600 ~/.gem/credentials

# Install the gem
gem install kiket-cli --source https://rubygems.pkg.github.com/kiket
```

### From Source

```bash
git clone https://github.com/kiket/cli.git
cd cli
bundle install
rake install_local
```

## Quick Start

### Authentication

```bash
# Login to Kiket
kiket auth login

# Check authentication status
kiket auth status
```

### Configuration

```bash
# Set default organization
kiket configure set default_org my-org

# View configuration
kiket configure list
```

## Commands

### Auth Commands

```bash
kiket auth login              # Authenticate with Kiket
kiket auth logout             # Remove stored credentials
kiket auth status             # Show authentication status
kiket auth token              # Display API token
```

### Marketplace Commands

```bash
kiket marketplace list                    # List available products
kiket marketplace info PRODUCT            # Show product details
kiket marketplace install PRODUCT         # Install a product
kiket marketplace upgrade INSTALLATION    # Upgrade installation
kiket marketplace uninstall INSTALLATION  # Uninstall product
kiket marketplace status [INSTALLATION]   # Show installation status
kiket marketplace metadata [PATH]         # Create/update .kiket/product.yaml metadata
kiket marketplace import SOURCE           # Import blueprint assets + metadata into the workspace
kiket marketplace sync_samples            # Copy reference bundles locally (with metadata manifests)
```

### Extensions Commands

```bash
kiket extensions scaffold NAME                  # Generate extension project
kiket extensions lint [PATH]                    # Lint extension
kiket extensions test [PATH]                    # Run tests
kiket extensions validate [PATH]                # Validate for publishing
kiket extensions publish [PATH]                 # Publish to marketplace (GitHub)
kiket extensions doctor [PATH]                  # Diagnose issues
```

### Workflows Commands

```bash
kiket workflows lint [PATH]                     # Validate workflows
kiket workflows test [PATH]                     # Test workflows
kiket workflows simulate WORKFLOW --input FILE  # Simulate execution
kiket workflows visualize WORKFLOW              # Generate diagram
kiket workflows diff --against BRANCH           # Compare workflows
```

### Definitions Commands

```bash
kiket definitions lint [PATH]                   # Lint workflows, dashboards, and dbt assets
```

### Secrets Commands

```bash
kiket secrets init                    # Initialize secret store
kiket secrets set KEY VALUE           # Set a secret
kiket secrets rotate KEY              # Rotate secret
kiket secrets list                    # List secrets
kiket secrets export --output .env    # Export to file
kiket secrets sync-from-env           # Sync from environment
```

### Analytics Commands

```bash
kiket analytics report usage          # Generate usage report
kiket analytics report billing        # Generate billing report
kiket analytics dashboard open        # Open dashboard in browser
```

### Sandbox Commands

```bash
kiket sandbox launch PRODUCT                # Create sandbox
kiket sandbox teardown SANDBOX_ID           # Delete sandbox
kiket sandbox refresh-data SANDBOX_ID       # Refresh demo data
kiket sandbox list                          # List sandboxes
```

### SLA Commands

```bash
kiket sla status                      # Show SLA status
kiket sla metrics PROJECT_ID          # Display SLA metrics
kiket sla breaches PROJECT_ID         # List SLA breaches
```

### Milestones Commands

```bash
kiket milestones list PROJECT_ID                   # List milestones
kiket milestones list PROJECT_ID --status active   # Filter by status
kiket milestones show PROJECT_ID MILESTONE_ID      # Show milestone details
kiket milestones create PROJECT_ID --name "Q1 Release" --target-date 2026-03-31
kiket milestones update PROJECT_ID MILESTONE_ID --status completed
kiket milestones delete PROJECT_ID MILESTONE_ID    # Delete with confirmation
kiket milestones delete PROJECT_ID MILESTONE_ID -f # Delete without confirmation
```

### Issues Commands

```bash
# List and filter issues
kiket issues list PROJECT_ID                       # List issues
kiket issues list PROJECT_ID --status done         # Filter by status
kiket issues list PROJECT_ID --type bug            # Filter by type (Epic, UserStory, Task, Bug)
kiket issues list PROJECT_ID --assignee 5          # Filter by assignee ID
kiket issues list PROJECT_ID --label urgent        # Filter by label
kiket issues list PROJECT_ID --search "login"      # Search in title

# Issue CRUD
kiket issues show ISSUE_KEY                        # Show issue details
kiket issues create PROJECT_ID --title "Fix bug" --type Bug --priority high
kiket issues create PROJECT_ID --title "Task" --parent 10 --custom-fields '{"sprint":"Sprint 1"}'
kiket issues update ISSUE_KEY --status done        # Update issue fields
kiket issues update ISSUE_KEY --custom-fields '{"story_points":5}'
kiket issues transition ISSUE_KEY done             # Transition workflow state
kiket issues delete ISSUE_KEY                      # Delete with confirmation
kiket issues delete ISSUE_KEY -f                   # Delete without confirmation

# Issue schema (discover types, fields, statuses)
kiket issues schema PROJECT_ID                     # Show available types, statuses, custom fields

# Comments
kiket issues comments list ISSUE_KEY               # List comments
kiket issues comments add ISSUE_KEY "My comment"   # Add a comment
kiket issues comments update ISSUE_KEY 123 "New text"  # Update comment
kiket issues comments delete ISSUE_KEY 123         # Delete comment
```

### Doctor Commands

```bash
kiket doctor run                      # Run health checks
kiket doctor run --extensions         # Check extensions
kiket doctor run --workflows          # Check workflows
```

## Configuration

The CLI stores configuration in `~/.kiket/config`:

```yaml
api_base_url: https://kiket.dev
api_token: your-token-here
default_org: your-org-slug
output_format: human
verbose: false
```

You can also use environment variables:

```bash
export KIKET_API_URL=https://kiket.dev
export KIKET_API_TOKEN=your-token-here
export KIKET_DEFAULT_ORG=your-org-slug
```

## Output Formats

Control output format with `--format`:

```bash
kiket marketplace list --format json    # JSON output
kiket marketplace list --format csv     # CSV output
kiket marketplace list --format human   # Human-readable (default)
```

## Development

### Setup

```bash
bundle install
```

### Testing

```bash
bundle exec rspec
```

### Linting

```bash
bundle exec rubocop
bundle exec rubocop -A  # Auto-fix
```

### Building

```bash
# Build the gem
gem build kiket-cli.gemspec

# Install locally for testing
gem install ./kiket-cli-*.gem
```

### Publishing

The gem is automatically published to GitHub Packages when a new version tag is pushed:

```bash
# 1. Update version in lib/kiket/version.rb
# 2. Update CHANGELOG.md
# 3. Commit changes
git add lib/kiket/version.rb CHANGELOG.md
git commit -m "Bump version to 0.2.0"

# 4. Create and push tag
git tag v0.2.0
git push origin main
git push origin v0.2.0
```

The GitHub Actions workflow will:
- Run tests and RuboCop
- Build the gem
- Publish to GitHub Packages
- Create a GitHub Release

### CI/CD

Two GitHub Actions workflows are configured:

**CI Workflow** (`.github/workflows/ci.yml`)
- Runs on every push and pull request
- Tests against Ruby 3.0, 3.1, 3.2, 3.3, 3.4
- Runs RuboCop linter
- Runs RSpec tests
- Verifies gem builds successfully
- Tests CLI installation

**Publish Workflow** (`.github/workflows/publish.yml`)
- Runs when a version tag is pushed (e.g., `v0.1.0`)
- Verifies version matches tag
- Runs full test suite
- Publishes to GitHub Packages
- Creates GitHub Release with gem artifact

### Console

```bash
rake console
```

## Extension Development

### Scaffold a New Extension

```bash
kiket extensions scaffold my-extension --sdk python
cd my-extension
```

### Test Your Extension

```bash
kiket extensions lint
kiket extensions test
kiket extensions doctor
```

### Publish

```bash
kiket extensions publish
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -am 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT License. See [LICENSE](LICENSE) for details.

## Support

- Documentation: https://docs.kiket.dev
- Issues: https://github.com/kiket/cli/issues
- Community: https://community.kiket.dev

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.
