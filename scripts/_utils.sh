
# Terminate script if a command exits with a non-zero status.
set -e


# Text formatting (ANSI escape codes for portability)
normal='\033[0m'
bold='\033[1m'
italic='\033[3m'
green='\033[0;32m'
bold_green='\033[1;32m'
yellow='\033[0;33m'
bold_yellow='\033[1;33m'
blue='\033[0;34m'
bold_blue='\033[1;34m'
red='\033[0;31m'
bold_red='\033[1;31m'
unitalic='\033[23m'

print_step() { echo -e "${normal}$1"; }
print_header() { echo -e "${bold}$1${normal}"; }
print_success() { echo -e "${green}$1${normal}"; }
print_success_header() { echo -e "${bold_green}$1${normal}"; }
print_warning() { echo -e "${yellow}$1${normal}" >&2; }
print_warning_header() { echo -e "${bold_yellow}$1${normal}"; }
print_error() { echo -e "${red}$1${normal}" >&2; }
print_error_header() { echo -e "${bold_red}$1${normal}"; }

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
	machine_list=$(podman machine list --format "{{.Name}}" 2>/dev/null || true)

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

# Ensure container is running and ready (after creation)
ensure_container_ready_old() {
	local container_name="$1"
	local service_check="${2:-}"
	local timeout="${3:-30}"

	# Ensure container is running
	start_container_if_not_running "$container_name" || return 1

	# Wait for container to be running
	podman wait --condition=running "$container_name" >/dev/null 2>&1 || {
		print_error "Container $container_name failed to start"
		return 1
	}

	# Wait for container to be healthy (if health check is available)
	if podman inspect --format '{{.State.Health}}' "$container_name" >/dev/null 2>&1; then
		podman wait --condition=healthy "$container_name" >/dev/null 2>&1 || {
			print_error "Container $container_name failed to become healthy"
			return 1
		}
	fi

	# If service check command is provided, wait for service to be ready
	if [[ -n "$service_check" ]]; then
		print_step "Waiting for service in $container_name to be ready..."
		local start_time=$(date +%s)
		while true; do
			if podman exec "$container_name" $service_check 2>/dev/null | grep -q "$service_check"; then
				break
			fi
			local current_time=$(date +%s)
			if [[ $((current_time - start_time)) -gt $timeout ]]; then
				print_error "Timeout waiting for service in $container_name to be ready"
				return 1
			fi
			sleep 0.5
		done
	fi

	print_step "Container $container_name is ready"
	return 0
}

# ensure_container_ready <container_name> [timeout_seconds]
ensure_container_ready() {
	local container_name="$1"
	local timeout="${2:-30}"

	if [[ -z "$container_name" ]]; then
		echo "ERROR: container name is required" >&2
		return 1
	fi

	# 1. Ensure container exists
	if ! podman container exists "$container_name"; then
		echo "ERROR: container '$container_name' does not exist" >&2
		return 1
	fi

	# 2. Start container if not running
	local status
	status=$(podman inspect -f '{{.State.Status}}' "$container_name")
	if [[ "$status" != "running" ]]; then
		echo "Starting container '$container_name'..."
		if ! podman start "$container_name" >/dev/null; then
			echo "ERROR: failed to start container '$container_name'" >&2
			return 1
		fi
	fi

	# 3. Wait until container process is running
	local start_time
	start_time=$(date +%s)
	while true; do
		status=$(podman inspect -f '{{.State.Status}}' "$container_name")
		if [[ "$status" == "running" ]]; then
			break
		fi
		if (( $(date +%s) - start_time >= timeout )); then
			echo "ERROR: container '$container_name' did not reach running state in $timeout seconds" >&2
			return 1
		fi
		sleep 0.5
	done

	# 4. Wait until container can execute commands
	start_time=$(date +%s)
	while true; do
		if podman exec "$container_name" true >/dev/null 2>&1; then
			break
		fi
		if (( $(date +%s) - start_time >= timeout )); then
			echo "ERROR: container '$container_name' exists and is running but cannot execute commands" >&2
			return 1
		fi
		sleep 0.5
	done

	echo "Container '$container_name' is ready for commands"
	return 0
}


# wait_for_command_in_container <container_name> <timeout_seconds> <command...>
wait_for_command_in_container() {
	local container_name="$1"
	local timeout="${2:-30}"
	shift 2
	local cmd=("$@")

	if [[ -z "$container_name" || ${#cmd[@]} -eq 0 ]]; then
		echo "ERROR: container name and command are required" >&2
		return 1
	fi

	local start_time
	start_time=$(date +%s)

	while true; do
		if podman exec "$container_name" "${cmd[@]}" >/dev/null 2>&1; then
			echo "Command succeeded in container '$container_name'"
			return 0
		fi

		if (( $(date +%s) - start_time >= timeout )); then
			echo "ERROR: command failed in container '$container_name' after $timeout seconds" >&2
			return 1
		fi

		sleep 0.5
	done
}


# Confirm dangerous actions
	# Args: 1/ Prompt message
confirm_action() {
	local message="$1"

	# If not interactive stdin or not a TTY, assume yes
	if [[ ! -t 0 ]]; then
		return 0
	fi

	echo -ne "${bold}${message} Continue? (yes/no): ${normal}"
	read -r answer

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
