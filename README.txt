# apptools

A set of Bash-based command-line tools for orchestrating common development and project management tasks.

## Features

- Run commands directly from GitHub without local installation
- Unified toolset for monorepo development
- Supports Node.js, PostgreSQL, SQLite, containers (Podman), and Playwright
- Environment variable-based configuration
- Comprehensive logging and error handling

## Installation

### Quick Install (Recommended)
```bash
curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- install --src https://github.com/danfortsystems/apptools --target "$HOME/.local/bin/apptools" --main project
```

This will:
- Install AppTools to `~/.local/bin/apptools`
- Create a symlink so you can run `project` directly from your PATH

### Manual Installation
1. Clone the repository:
```bash
git clone https://github.com/danfortsystems/apptools.git
cd apptools
```

2. Install to a local directory:
```bash
mkdir -p "$HOME/.local/bin/apptools"
cp * "$HOME/.local/bin/apptools/"
ln -sf "$HOME/.local/bin/apptools/project" "$HOME/.local/bin/project"
```

3. Ensure `~/.local/bin` is in your PATH:
```bash
# For bash
echo 'export PATH="$PATH:$HOME/.local/bin"' >> ~/.bashrc

# For zsh
echo 'export PATH="$PATH:$HOME/.local/bin"' >> ~/.zshrc
```

## Usage

### Without Installation (Remote Execution)
You can run AppTools commands directly from GitHub without installing:

```bash
# Install dependencies
curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- deps

# Build the project
curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- build

# Run tests
curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- test

# Start development server
curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- dev

# Start production server
curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- start
```

### With Local Installation
After installing locally, you can run commands directly:

```bash
project deps
project build
project test
project dev
project start
```

## Available Commands

- `deps` - Install dependencies (Node.js packages, databases, containers, browsers)
- `build` - Build application and database
- `test` - Run tests (units, API, GUI, E2E)
- `dev` - Start development server with file watching
- `start` - Start production server
- `deploy` - Deploy to git repository
- `install` - Install a project from source

## Environment Variables

AppTools uses environment variables for configuration:

- `NODE_ENV` - Development/production environment
- `DATABASE_URL` - PostgreSQL connection string
- `DB_PATH` - SQLite database file path
- `OBJECT_STORAGE_BUCKET` - MinIO bucket name
- `MSG_FROM_EMAIL_ADDRESS` - MailHog isolation
- `PLAYWRIGHT_BROWSERS_PATH` - Playwright browser installation path

## Requirements

- Bash shell
- curl or wget
- Node.js and pnpm (for JavaScript projects)
- Podman (for container services)
- PostgreSQL client (if using PostgreSQL)

## Documentation

See `SPECS.txt` for detailed technical specifications.