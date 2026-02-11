AppTools
A set of Bash-based command-line tools for orchestrating common development and project management tasks within monorepos. AppTools replaces project-specific shell scripts with a unified toolset, ensuring consistency and simplifying maintenance.

Features

	- Run commands directly from GitHub without local installation
	- Unified toolset for monorepo development
	- Supports Node.js, PostgreSQL, SQLite, containers (Podman), and Playwright
	- Environment variable-based configuration for project behavior
	- Comprehensive logging and error handling
	- Container Management:
		Container names are generic (minio, mailhog) for sharing across projects. Isolation is achieved through per-project buckets (for object storage) and per-project mail-from addresses (for SMTP), all of which as specified with env variables. Containers are installed based on presence of the env variables OBJECT_STORAGE_ROOT_URL (MinIO) and SMTP_HOST (MailHog). Se the Environment Variables section for more details.

Quick Install:
	curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- install --src https://github.com/danfortsystems/apptools --target "$HOME/.local/bin/apptools" --main project

	This command will:
		- Install AppTools to a user folder on the machine
		- Create a symlink so you can run 'project' directly from your PATH

Usage Reference

	Without Installation (Remote Execution):
		You can run AppTools commands directly from GitHub without installing:

		curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- <command>

		Examples:
		  curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- deps
		  curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- build
		  curl -fsSL https://raw.githubusercontent.com/danfortsystems/apptools/main/project | bash -s -- test

	With Local Installation:
		After installing locally, you can run commands directly:

		project <command>

		Examples:
		  project deps
		  project build
		  project test

	Available Commands

		deps [--reset <targets>]
			Install dependencies (Node.js packages, databases, containers, browsers)

			Arguments:
				--reset <targets>	- Comma-separated list of targets to reset before install (js, db, containers, browsers)

			Behavior:
				- Manages dependencies based on environment variables
				- Valid targets: js (Node.js packages), db (databases), containers (Podman), browsers (Playwright)
				- If no --reset specified, installs all available dependencies
				- If --reset specified, resets specified targets then installs all

			Examples:
				project deps							# Install all available dependencies
				project deps --reset						# Reset and reinstall all
				project deps --reset db,js				# Reset db and js, install others

		build [--dest <path>] [--only app|db] [--db-url <url>] [--db-path <path>] [--db-reset-ok]
			Build application and database

			Arguments:
				--dest <path>		- Output directory for build artifacts (default: ./dist)
				--only <app|db>		- Build only app code or only database
				--db-url <url>		- PostgreSQL connection URL for database build
				--db-path <path>	- SQLite database file path for database build
				--db-reset-ok		- Allow database reset when no migration script exists

			Behavior:
				- Processes SQL schema files to generate database initialization scripts
				- Compares existing schema with DDL scripts to detect changes
				- Generates db.init.sql always
				- Generates db.migrate.sql if schema differences detected
				- --db-reset-ok flag allows database reset when no migration script exists

			Examples:
				project build							# Full build to ./dist
				project build --dest ./build				# Build to custom directory
				project build --only db					# Database build only
				project build --only app --dest ./build	# App build only to custom directory

		test [--build-dir <dir>] [--no-db-create] [--db-url <url>] [--keep-db-file] [--log-dir <dir>] [--only <types>] [--fast]
			Run tests (units, API, GUI, E2E)

			Arguments:
				--build-dir <dir>		- Directory containing build artifacts (default: ./dist)
				--no-db-create		- Don't create a random test database (uses DATABASE_URL as-is)
				--db-url <url>		- Database connection URL (overrides DATABASE_URL env var)
				--keep-db-file		- Keep db.migrate.sql file after successful migration
				--log-dir <dir>		- Custom directory for test logs (default: ./logs/test/<timestamp>)
				--only <types>		- Run only specified test types (comma-separated: units,api,gui,e2e)
				--fast				- Use fast Playwright configuration (Chrome only, faster execution)

			Behavior:
				- Manages test environment including database setup
				- Runs different test types based on configuration
				- Cleans up resources after completion

			Examples:
				project test							# Run all tests
				project test --only units				# Run only unit tests
				project test --only api,gui			# Run API and GUI tests
				project test --fast					# Run all tests with fast config

		dev [--db-url <url>] [--port <port>]
			Start development server with file watching

			Arguments:
				--db-url <url>		- Database connection URL (overrides DATABASE_URL env var)
				--port <port>		- Server port (overrides PORT env var)

			Behavior:
				- Starts development server with file watching using watchexec
				- Automatically rebuilds and restarts on file changes
				- Invokes build and start commands with arguments

			Examples:
				project dev --db-url "postgres://localhost:5432/mydb" --port 3000
				project dev --port 3000

		start [--db-url <url>] [--db-path <path>] [--port <port>]
			Start production server

			Arguments:
				--db-url <url>		- Database connection URL (overrides DATABASE_URL env var)
				--db-path <path>	- SQLite database file path (overrides DB_PATH env var)
				--port <port>		- Server port (overrides PORT env var)

			Behavior:
				- Starts the application server
				- Manages required services (containers) if using local services
				- Kills any existing process using the target port
				- Runs database migration if db.migrate.sql exists
				- Requires server bundle at ./dist/server.bundle.cjs

			Examples:
				project start --db-url "postgres://localhost:5432/mydb" --port 3000
				project start --db-path "./data/myapp.db" --port 3000

		deploy [--update-level <patch|minor|major>] [--include <files>] [--exclude <files>] --repo <url>
			Deploy to git repository

			Arguments:
				--update-level <patch|minor|major>	- Semver update level for version bump (defaults to patch)
				--include <files>					- Files to include in deployment (comma-separated)
				--exclude <files>					- Files to exclude from deployment (comma-separated)
				--repo <url>						- URL of remote git repo to deploy to

			Behavior:
				- Ensures project is git-wise clean (no pending changes)
				- Calls build script with output folder set to temporary folder
				- Updates project version in package.json (according to semver level)
				- Commits with appropriate tag and pushes
				- Creates package.json in build output folder with project metadata
				- Removes excluded files from deployment
				- Initializes git repo in build output folder and pushes to target repo

			Examples:
				project deploy --update-level minor --repo https://github.com/user/repo.git
				project deploy --include "*.js,*.css" --exclude "*.map" --repo https://github.com/user/repo.git

			Remarks:
				This deployment approach works for GitHub-based deploys to PaaS platforms like Render.com.
				The PaaS project is connected to a dedicated deploy-only GitHub repo, not the main source repo.

		install --src <url OR folder path> --target <local-install-folder-path> --main <main-binary-file> [--version <version-number-tag>]
			Install a project from source

			Arguments:
				--src <url OR folder path>			- Source: GitHub repo URL or local folder path
				--target <local-install-folder-path>	- Target local folder path to install files
				--main <main-binary-file>			- Name of primary executable file
				--version <version-number-tag>		- Version tag to install (GitHub only)

			Behavior:
				- Creates target installation directory if it doesn't exist
				- Copies or downloads installation files from source
				- For GitHub: downloads archive, extracts, moves contents to target
				- Sets proper permissions on main executable
				- Creates symlink in standard user bin directory (e.g., ~/.local/bin)
				- Runs initialization tasks with --init flag
				- Verifies installation with --version flag

			Examples:
				install --src https://github.com/user/repo.git --target /path/to/install --main myapp --version v1.0.0
				install --src ./local/path --target ~/apps/myapp --main myapp

Configuration

	Projects managed with AppTools can use environment variables to configure how AppTools operates on them:

	- NODE_ENV
		Development/production environment (dev/prod), default: dev
	
	- DATABASE_URL
		PostgreSQL database connection string (format: postgres://user:pass@host:port/dbname) Controls database reset/install operations. When set, enables PostgreSQL database management.
	
	- DB_PATH
		SQLite database file path Controls database file location for SQLite databases. When set, enables SQLite database management and creates the database file if it doesn't exist.

	- OBJECT_STORAGE_ROOT_URL
		Root url for S3-compatible object storage used by a project. When set to a local machine url (e.g., http://localhost:9000), enables the installation and configuration of the MinIO local object storage container by AppTools for testing.
	
	- OBJECT_STORAGE_BUCKET
		Object storage bucket name used by the project. For local object storage as defined by OBJECT_STORAGE_ROOT_URL, it is used to create project-specific storage areas within the same MinIO container.
	
	- OBJECT_STORAGE_ACCESS_KEY_ID
		Authentication key for object storage service. When OBJECT_STORAGE_ROOT_URL is set to a local url, defines the access key for MinIO authentication.
	
	- OBJECT_STORAGE_ACCESS_KEY_SECRET:
		Authentication secret for object storage service. When OBJECT_STORAGE_ROOT_URL is set to a local url, defines the access key secret for MinIO authentication.
	
	- SMTP_HOST
		STMP server host used by the project. When set to a local url (e.g., http://localhost:1025), triggers MailHog container installation for email testing during development.
	
	- MSG_FROM_EMAIL_ADDRESS
		Email address to use for sending emails for a project by SMTP. For local testing, enables per-project email separation in MailHog.
	
	- PLAYWRIGHT_BROWSERS_PATH
		Path for Playwright browser installations. When set, triggers Playwright browser installation for UI testing.

Requirements

	- Bash shell
	- Standard Unix/Linux tools (curl, wget, tar, rsync, sed, openssl)
	- Git version control (for deployment and version operations)
	- PostgreSQL and SQLite database engines (if using database features)
	- Node.js runtime and package manager (pnpm/bun/npm - only for projects using Node.js)
	- Podman Container Engine (for managing local development services)
		- macOS: brew install podman && podman machine init && podman machine start
		- Linux: Refer to your distribution's documentation (e.g., sudo apt install podman for Debian/Ubuntu, sudo dnf install podman for Fedora)

See Also

	See SPECS.txt for detailed technical specifications.
