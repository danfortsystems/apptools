
# Terminate script if a command exits with a non-zero status.
set -e


# Text formatting (ANSI escape codes for portability)
bold='\033[1m'
normal='\033[0m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
red='\033[0;31m'

print_header() {
	echo -e "${bold}$1${normal}"
}
print_step() {
	echo -e "${normal}$1"
}
print_warning() {
	echo -e "${yellow}$1${normal}" >&2
}
print_error() {
	echo -e "${bold}${red}$1${normal}" >&2
}

# Find unused port in 3000–3999 range sequentially
find_unused_port() {
	for PORT in {3000..3999}; do
		if ! lsof -i:$PORT >/dev/null 2>&1; then
			echo $PORT
			return
		fi
	done
	echo "Could not find a free port in the 3000-3999 range." >&2
	exit 1
}

# Wait for a port to become available
	# Args: 1/ Port number. 2/ Timeout in seconds (optional, defaults to 30)
wait_for_port() {
	local port=$1
	local timeout=${2:-30}
	local count=0

	# Check if nc command is available
	if ! command -v nc >/dev/null 2>&1; then
		print_error "netcat (nc) command not found. Please install netcat."
		return 1
	fi

	print_step "Waiting for port $port to be ready..."

	while ! nc -z localhost $port >/dev/null 2>&1; do
		sleep 1
		count=$((count + 1))
		if [[ $count -gt $timeout ]]; then
			print_error "Timeout waiting for port $port after ${timeout}s"
			return 1
		fi
	done

	print_step "Port $port is ready"
}


# Ensure Podman and its virtual machine is installed and running; exit otherwise
checkPodmanMachine() {
	# Ensure Podman is installed
	if ! command -v podman >/dev/null 2>&1; then
		print_error "Podman is not installed. Skipping reset."
		exit 1
	fi

	# Ensure Podman machine exists
	local machine_list
	machine_list=$(podman machine list --format "{{.Names}}" 2>/dev/null || true)

	if [[ -z "$machine_list" ]]; then
		print_step "Creating Podman machine..."
		podman machine init >/dev/null 2>&1 || {
			print_error "Failed to initialize Podman machine"
			exit 1
		}
	fi

	# Ensure Podman machine is running
	local state
	state=$(podman machine inspect --format '{{.State}}' 2>/dev/null || echo "not-running")

	if [[ "$state" != "running" ]]; then
		print_step "Starting Podman machine..."
		podman machine start >/dev/null 2>&1 || {
			print_error "Failed to start Podman machine"
			exit 1
		}
		print_step "Done starting Podman machine"
	fi
}

# Container management helpers
ensure_container_exists() {
	local container_name="$1"
	local image="$2"
	local ports="$3"
	local env_vars="$4"

	if ! podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
		print_step "Creating container $container_name..."
		podman run -d --name "$container_name" $ports $env_vars $image >/dev/null 2>&1 || {
			print_error "Failed to create container $container_name"
			return 1
		}
	fi
}

start_container_if_not_running() {
	local container_name="$1"

	if ! podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
		print_step "Starting container $container_name..."
		podman start "$container_name" >/dev/null 2>&1 || {
			print_error "Failed to start container $container_name"
			return 1
		}
	fi
}


# Confirm dangerous actions
	# Args: 1/ Prompt message
confirm_action() {
	local message="$1"

	# If not interactive stdin or not a TTY, assume yes
	if [[ ! -t 0 ]]; then
		return 0
	fi

	read -p "$message Continue? (yes/no): " -r answer

	# Trim leading/trailing whitespace and convert to lowercase
	answer="$(echo "$answer" | xargs | tr '[:upper:]' '[:lower:]')"

	case "$answer" in
		yes|YES|y|Y)
			return 0
			;;
		*)
			return 1
			;;
	esac
}


# Check if a URL points to a local service (localhost or 127.0.0.1)
is_local_url() {
    local url="$1"
    [[ "$url" =~ ^https?://(localhost|127\.0\.0\.1)(:|/|$) ]]
}
