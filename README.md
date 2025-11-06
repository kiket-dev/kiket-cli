# Kiket CLI

Official command-line interface for the Kiket workflow automation platform.

## Installation

```bash
gem install kiket-cli
```

Or install from source:

```bash
git clone https://github.com/kiket/cli.git
cd cli
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
```

### Extensions Commands

```bash
kiket extensions scaffold NAME                  # Generate extension project
kiket extensions lint [PATH]                    # Lint extension
kiket extensions test [PATH]                    # Run tests
kiket extensions package [PATH]                 # Package extension
kiket extensions publish [PATH]                 # Publish to marketplace
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
