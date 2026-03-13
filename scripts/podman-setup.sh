#!/usr/bin/env bash
# Semian Podman Development Setup Script
# Usage: ./scripts/podman-setup.sh <command> [options]
#
# Commands:
#   init      Initialize Podman machine and start all services
#   test      Run the test suite
#   shell     Drop into container shell for development
#   clean     Stop and remove containers
#   status    Show status of services and containers
#   logs      Tail logs from services
#
# Options:
#   --verbose   Show detailed output
#   --help      Show this help message

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PODMAN_COMPOSE_FILE="${PROJECT_ROOT}/podman-compose.yml"
PODMAN_COMPOSE_CMD="podman-compose --in-pod false -f ${PODMAN_COMPOSE_FILE}"
REQUIRED_PODMAN_VERSION="4.0.0"
REQUIRED_PODMAN_COMPOSE_VERSION="1.0.0"
PODMAN_MACHINE_NAME="podman-machine-default"
PODMAN_MEMORY="4096"  # 4GB
PODMAN_CPUS="2"

# ==============================================================================
# Colors (ANSI escape codes - no extra dependencies)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ==============================================================================
# Global Variables
# ==============================================================================

VERBOSE=false

# ==============================================================================
# Logging Functions
# ==============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${CYAN}[VERBOSE]${NC} $1"
    fi
}

log_step() {
    echo -e "${BOLD}==>${NC} $1"
}

# ==============================================================================
# Utility Functions
# ==============================================================================

print_usage() {
    cat << EOF
${BOLD}Semian Podman Development Setup${NC}

${BOLD}USAGE:${NC}
    ./scripts/podman-setup.sh <command> [options]

${BOLD}COMMANDS:${NC}
    ${GREEN}init${NC}       Initialize Podman machine and start all services
    ${GREEN}test${NC}       Run the test suite
    ${GREEN}shell${NC}      Drop into container shell for development
    ${GREEN}clean${NC}      Stop and remove containers
    ${GREEN}status${NC}     Show status of services and containers
    ${GREEN}logs${NC}       Tail logs from services

${BOLD}OPTIONS:${NC}
    --verbose      Show detailed output
    --help, -h     Show this help message

${BOLD}EXAMPLES:${NC}
    # Initialize everything
    ./scripts/podman-setup.sh init

    # Run tests with verbose output
    ./scripts/podman-setup.sh test --verbose

    # Run tests and skip flaky tests
    ./scripts/podman-setup.sh test --skip-flaky

    # Run tests with debugger
    ./scripts/podman-setup.sh test --debug

    # Get a development shell
    ./scripts/podman-setup.sh shell

    # Clean up everything
    ./scripts/podman-setup.sh clean

    # Clean up including volumes and machine
    ./scripts/podman-setup.sh clean --volumes --machine

    # View logs from MySQL
    ./scripts/podman-setup.sh logs mysql

${BOLD}DOCUMENTATION:${NC}
    See docs/PODMAN.md for comprehensive documentation

EOF
}

version_gt() {
    # Returns 0 if $1 > $2, 1 otherwise
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

check_command() {
    local cmd=$1
    if ! command -v "$cmd" &> /dev/null; then
        return 1
    fi
    return 0
}

check_macos() {
    [[ "$(uname -s)" == "Darwin" ]]
}

# ==============================================================================
# Dependency Checks
# ==============================================================================

check_podman() {
    log_verbose "Checking for Podman installation..."
    
    if ! check_command podman; then
        log_error "Podman is not installed!"
        echo ""
        echo "Install with:"
        if check_macos; then
            echo "  brew install podman"
        else
            echo "  See https://podman.io/getting-started/installation"
        fi
        echo ""
        exit 1
    fi
    
    local version
    version=$(podman --version | awk '{print $3}')
    log_success "Podman ${version} found"
    
    # Check if version is recent enough
    if version_gt "$REQUIRED_PODMAN_VERSION" "$version"; then
        log_warn "Podman version ${version} is older than recommended ${REQUIRED_PODMAN_VERSION}"
        log_warn "Consider updating: brew upgrade podman"
    fi
    
    log_verbose "Podman check complete"
}

check_podman_compose() {
    log_verbose "Checking for podman-compose installation..."
    
    if ! check_command podman-compose; then
        log_error "podman-compose is not installed!"
        echo ""
        echo "Install with:"
        if check_macos; then
            echo "  brew install podman-compose"
        else
            echo "  pip3 install podman-compose"
        fi
        echo ""
        exit 1
    fi
    
    local version
    version=$(podman-compose --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    log_success "podman-compose ${version} found"
    
    # Check if version is recent enough
    if version_gt "$REQUIRED_PODMAN_COMPOSE_VERSION" "$version"; then
        log_warn "podman-compose version ${version} is older than recommended ${REQUIRED_PODMAN_COMPOSE_VERSION}"
        log_warn "Consider updating: brew upgrade podman-compose"
    fi
    
    log_verbose "podman-compose check complete"
}

# ==============================================================================
# Podman Machine Management (macOS)
# ==============================================================================

ensure_podman_machine() {
    if ! check_macos; then
        log_verbose "Not on macOS, skipping Podman machine setup"
        return 0
    fi
    
    log_step "Ensuring Podman machine is set up..."
    
    # Check if any machine exists
    if ! podman machine list --format "{{.Name}}" 2>/dev/null | grep -q .; then
        log_info "No Podman machine found, initializing..."
        log_verbose "Creating machine with ${PODMAN_MEMORY}MB RAM and ${PODMAN_CPUS} CPUs"
        
        if podman machine init \
            --memory "$PODMAN_MEMORY" \
            --cpus "$PODMAN_CPUS" \
            --disk-size 100 \
            --rootful=false 2>&1 | while IFS= read -r line; do log_verbose "$line"; done; then
            log_success "Podman machine initialized"
        else
            log_error "Failed to initialize Podman machine"
            exit 1
        fi
    else
        # Check if the machine configuration is corrupt (missing SSH keys, etc)
        local machine_name
        machine_name=$(podman machine list --format "{{.Name}}" 2>/dev/null | head -n1)
        if [[ ! -f ~/.local/share/containers/podman/machine/machine ]]; then
            log_warn "Podman machine exists but appears to be corrupted (missing SSH keys)"
            log_info "This can happen with old machines or after Podman upgrades"
            echo ""
            echo "To fix this, we need to recreate the machine."
            echo "This will NOT delete your containers or images."
            echo ""
            read -p "Recreate Podman machine? (y/n) " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "Removing old machine..."
                podman machine rm -f "$machine_name" 2>&1 | while IFS= read -r line; do log_verbose "$line"; done
                
                log_info "Creating new machine with ${PODMAN_MEMORY}MB RAM and ${PODMAN_CPUS} CPUs..."
                if podman machine init \
                    --memory "$PODMAN_MEMORY" \
                    --cpus "$PODMAN_CPUS" \
                    --disk-size 100 \
                    --rootful=false 2>&1 | while IFS= read -r line; do log_verbose "$line"; done; then
                    log_success "Podman machine recreated"
                else
                    log_error "Failed to recreate Podman machine"
                    exit 1
                fi
            else
                log_error "Cannot proceed without a working Podman machine"
                echo ""
                echo "To fix manually:"
                echo "  podman machine rm -f $machine_name"
                echo "  podman machine init"
                echo "  podman machine start"
                exit 1
            fi
        fi
    fi
    
    # Check if machine is running
    local machine_status
    machine_status=$(podman machine list --format "{{.Running}}" 2>/dev/null | head -n1)
    
    if [[ "$machine_status" != "true" ]]; then
        log_info "Starting Podman machine..."
        
        # Try to start the machine
        local start_output
        start_output=$(podman machine start 2>&1)
        local start_result=$?
        
        if [[ $start_result -eq 0 ]]; then
            log_success "Podman machine started"
        else
            # Check for common error: stale socket files
            if echo "$start_output" | grep -q "gvproxy.*socket"; then
                log_warn "Found stale socket files, cleaning up..."
                log_verbose "$start_output"
                
                # Clean up stale sockets
                local tmpdir="/var/folders"
                if [[ -d "/var/folders" ]]; then
                    find "$tmpdir" -name "podman-machine-*-gvproxy.sock" -type s 2>/dev/null | while read -r sock; do
                        log_verbose "Removing stale socket: $sock"
                        rm -f "$sock" 2>/dev/null || true
                    done
                fi
                
                # Try starting again
                log_info "Retrying Podman machine start..."
                if podman machine start 2>&1 | while IFS= read -r line; do log_verbose "$line"; done; then
                    log_success "Podman machine started"
                else
                    log_error "Failed to start Podman machine after cleanup"
                    echo ""
                    echo "Try manually:"
                    echo "  podman machine stop"
                    echo "  podman machine start"
                    echo ""
                    exit 1
                fi
            else
                log_error "Failed to start Podman machine"
                log_verbose "$start_output"
                echo ""
                echo "Error output:"
                echo "$start_output"
                echo ""
                echo "Try manually:"
                echo "  podman machine stop"
                echo "  podman machine start"
                echo ""
                exit 1
            fi
        fi
    else
        log_success "Podman machine is running"
    fi
}

# ==============================================================================
# Service Health Checks
# ==============================================================================

wait_for_mysql() {
    log_info "Waiting for MySQL to be ready..."
    local attempts=0
    local max_attempts=60
    
    while ! podman exec mysql mysqladmin ping -h localhost -uroot -proot --silent 2>/dev/null; do
        sleep 1
        attempts=$((attempts + 1))
        
        if (( attempts >= max_attempts )); then
            log_error "MySQL failed to start within ${max_attempts} seconds"
            return 1
        fi
        
        if (( attempts % 10 == 0 )); then
            log_verbose "Still waiting for MySQL... (${attempts}s)"
        fi
    done
    
    log_success "MySQL is ready"
}

wait_for_redis() {
    log_info "Waiting for Redis to be ready..."
    local attempts=0
    local max_attempts=30
    
    while ! podman exec redis redis-cli ping 2>/dev/null | grep -q PONG; do
        sleep 1
        attempts=$((attempts + 1))
        
        if (( attempts >= max_attempts )); then
            log_error "Redis failed to start within ${max_attempts} seconds"
            return 1
        fi
        
        if (( attempts % 10 == 0 )); then
            log_verbose "Still waiting for Redis... (${attempts}s)"
        fi
    done
    
    log_success "Redis is ready"
}

wait_for_postgres() {
    log_info "Waiting for PostgreSQL to be ready..."
    local attempts=0
    local max_attempts=30
    
    while ! podman exec postgres pg_isready -U postgres 2>/dev/null | grep -q "accepting connections"; do
        sleep 1
        attempts=$((attempts + 1))
        
        if (( attempts >= max_attempts )); then
            log_error "PostgreSQL failed to start within ${max_attempts} seconds"
            return 1
        fi
        
        if (( attempts % 10 == 0 )); then
            log_verbose "Still waiting for PostgreSQL... (${attempts}s)"
        fi
    done
    
    log_success "PostgreSQL is ready"
}

wait_for_services() {
    log_step "Waiting for services to be healthy..."
    
    if ! wait_for_mysql; then
        return 1
    fi
    
    if ! wait_for_redis; then
        return 1
    fi
    
    if ! wait_for_postgres; then
        return 1
    fi
    
    log_success "All services are healthy"
}

# ==============================================================================
# Command: init
# ==============================================================================

cmd_init() {
    log_step "Initializing Semian development environment with Podman..."
    echo ""
    
    # Check dependencies
    check_podman
    check_podman_compose
    echo ""
    
    # Ensure Podman machine (macOS only)
    ensure_podman_machine
    echo ""
    
    # Clean up any existing pods (from previous runs with different config)
    log_verbose "Checking for existing pods..."
    if podman pod list --format "{{.Name}}" 2>/dev/null | grep -q "pod_semian"; then
        log_info "Removing existing pod from previous run..."
        podman pod rm -f pod_semian 2>&1 | while IFS= read -r line; do log_verbose "$line"; done || true
    fi
    
    # Pull images
    log_step "Pulling Docker images..."
    if $PODMAN_COMPOSE_CMD pull 2>&1 | while IFS= read -r line; do log_verbose "$line"; done; then
        log_success "Images pulled"
    else
        log_warn "Some images may have failed to pull, continuing anyway..."
    fi
    echo ""
    
    # Start services
    log_step "Starting services..."
    if $PODMAN_COMPOSE_CMD up -d 2>&1 | while IFS= read -r line; do log_verbose "$line"; done; then
        log_success "Services started"
    else
        log_error "Failed to start services"
        exit 1
    fi
    echo ""
    
    # Wait for services to be healthy
    if ! wait_for_services; then
        log_error "Services failed to become healthy"
        echo ""
        echo "Try checking logs with:"
        echo "  ./scripts/podman-setup.sh logs"
        exit 1
    fi
    echo ""
    
    # Install dependencies
    log_step "Installing Ruby dependencies..."
    if podman exec semian bash -c "bundle install" 2>&1 | while IFS= read -r line; do log_verbose "$line"; done; then
        log_success "Dependencies installed"
    else
        log_error "Failed to install dependencies"
        exit 1
    fi
    echo ""
    
    # Build C extensions
    log_step "Building C extensions..."
    if podman exec semian bash -c "bundle exec rake build" 2>&1 | while IFS= read -r line; do log_verbose "$line"; done; then
        log_success "C extensions built"
    else
        log_error "Failed to build C extensions"
        exit 1
    fi
    echo ""
    
    # Success!
    echo -e "${GREEN}${BOLD}🎉 Setup complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  ${CYAN}Run tests:${NC}    ./scripts/podman-setup.sh test"
    echo "  ${CYAN}Get a shell:${NC}  ./scripts/podman-setup.sh shell"
    echo "  ${CYAN}View status:${NC}  ./scripts/podman-setup.sh status"
    echo "  ${CYAN}View logs:${NC}    ./scripts/podman-setup.sh logs"
    echo ""
}

# ==============================================================================
# Command: test
# ==============================================================================

cmd_test() {
    local skip_flaky=false
    local debug=false
    local test_pattern=""
    
    # Parse test-specific flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-flaky)
                skip_flaky=true
                shift
                ;;
            --debug)
                debug=true
                shift
                ;;
            --only)
                test_pattern="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    log_step "Running Semian test suite..."
    echo ""
    
    # Verify base services are running (mysql, redis, etc.)
    log_info "Checking if services are running..."
    if ! podman ps --format "{{.Names}}" | grep -q "mysql"; then
        log_error "Services are not running"
        echo ""
        echo "Start services first with:"
        echo "  ./scripts/podman-setup.sh init"
        exit 1
    fi
    
    # Check service health quickly
    if ! podman exec mysql mysqladmin ping -h localhost -uroot -proot --silent 2>/dev/null; then
        log_error "MySQL is not responding"
        exit 1
    fi
    log_success "Services are running"
    echo ""
    
    # Prepare environment variables
    local env_args=""
    if [[ "$skip_flaky" == "true" ]]; then
        env_args="-e SKIP_FLAKY_TESTS=true"
        log_info "Skipping flaky tests"
    fi
    
    if [[ "$debug" == "true" ]]; then
        env_args="$env_args -e DEBUG=true"
        log_info "Running with debugger (port 12345 will be exposed)"
        log_info "Connect your debugger to localhost:12345"
    fi
    
    # Run tests using dedicated test container (matches CI behavior)
    log_info "Running tests in dedicated test container..."
    log_verbose "Test container has hostname 'http-server' for network tests"
    
    if [[ -n "$test_pattern" ]]; then
        log_info "Running tests matching pattern: ${test_pattern}"
        # Override command to run specific tests
        if podman-compose --in-pod false -f "$PODMAN_COMPOSE_FILE" \
            --profile test run --rm $env_args test \
            bash -c "cd /workspace && bundle exec rake test TEST='test/**/*${test_pattern}*_test.rb'"; then
            log_success "Tests passed!"
        else
            log_error "Tests failed!"
            exit 1
        fi
    else
        # Use default command from compose file (runs scripts/run_tests.sh)
        if podman-compose --in-pod false -f "$PODMAN_COMPOSE_FILE" \
            --profile test run --rm $env_args test; then
            log_success "Tests passed!"
        else
            log_error "Tests failed!"
            exit 1
        fi
    fi
}

# ==============================================================================
# Command: shell
# ==============================================================================

cmd_shell() {
    log_step "Opening shell in Semian container..."
    echo ""
    
    # Verify container is running
    if ! podman ps --format "{{.Names}}" | grep -q "^semian$"; then
        log_error "Semian container is not running"
        echo ""
        echo "Start services first with:"
        echo "  ./scripts/podman-setup.sh init"
        exit 1
    fi
    
    # Check if bundle install is needed
    if ! podman exec semian bash -c "bundle check" &>/dev/null; then
        log_info "Dependencies need updating, running bundle install..."
        podman exec semian bash -c "bundle install"
    fi
    
    log_info "Dropping into shell..."
    echo ""
    log_warn "Note: HTTP/network tests may fail in this shell due to hostname requirements."
    log_info "For running the full test suite, use: ./scripts/podman-setup.sh test"
    echo ""
    podman exec -it semian bash
}

# ==============================================================================
# Command: clean
# ==============================================================================

cmd_clean() {
    local remove_volumes=false
    local stop_machine=false
    
    # Parse clean-specific flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --volumes)
                remove_volumes=true
                shift
                ;;
            --machine)
                stop_machine=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    log_step "Cleaning up Semian environment..."
    echo ""
    
    # Stop and remove containers
    log_info "Stopping containers..."
    if $PODMAN_COMPOSE_CMD down 2>&1 | while IFS= read -r line; do log_verbose "$line"; done; then
        log_success "Containers stopped and removed"
    else
        log_warn "Some containers may have already been removed"
    fi
    
    # Remove volumes if requested
    if [[ "$remove_volumes" == "true" ]]; then
        log_info "Removing volumes..."
        if podman volume ls -q | grep -q .; then
            podman volume ls -q | xargs -r podman volume rm 2>&1 | while IFS= read -r line; do log_verbose "$line"; done
            log_success "Volumes removed"
        else
            log_info "No volumes to remove"
        fi
    fi
    
    # Stop Podman machine if requested (macOS only)
    if [[ "$stop_machine" == "true" ]] && check_macos; then
        log_info "Stopping Podman machine..."
        if podman machine stop 2>&1 | while IFS= read -r line; do log_verbose "$line"; done; then
            log_success "Podman machine stopped"
        else
            log_warn "Podman machine may have already been stopped"
        fi
    fi
    
    echo ""
    log_success "Cleanup complete!"
}

# ==============================================================================
# Command: status
# ==============================================================================

cmd_status() {
    log_step "Semian Environment Status"
    echo ""
    
    # Podman machine status (macOS)
    if check_macos; then
        echo -e "${BOLD}Podman Machine:${NC}"
        if podman machine list 2>/dev/null; then
            echo ""
        else
            echo "  Not available"
            echo ""
        fi
    fi
    
    # Container status
    echo -e "${BOLD}Containers:${NC}"
    if podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(NAMES|semian|mysql|redis|postgres|toxiproxy)"; then
        echo ""
    else
        echo "  No containers found"
        echo ""
    fi
    
    # Quick health checks
    echo -e "${BOLD}Service Health:${NC}"
    
    # MySQL
    if podman exec mysql mysqladmin ping -h localhost -uroot -proot --silent 2>/dev/null; then
        echo -e "  MySQL:      ${GREEN}✓ Healthy${NC}"
    else
        echo -e "  MySQL:      ${RED}✗ Not responding${NC}"
    fi
    
    # Redis
    if podman exec redis redis-cli ping 2>/dev/null | grep -q PONG; then
        echo -e "  Redis:      ${GREEN}✓ Healthy${NC}"
    else
        echo -e "  Redis:      ${RED}✗ Not responding${NC}"
    fi
    
    # PostgreSQL
    if podman exec postgres pg_isready -U postgres 2>/dev/null | grep -q "accepting connections"; then
        echo -e "  PostgreSQL: ${GREEN}✓ Healthy${NC}"
    else
        echo -e "  PostgreSQL: ${RED}✗ Not responding${NC}"
    fi
    
    echo ""
    
    # SysV Semaphores info (if semian container is running)
    if podman ps --format "{{.Names}}" | grep -q "^semian$"; then
        echo -e "${BOLD}SysV Semaphores:${NC}"
        if podman exec semian cat /proc/sys/kernel/sem 2>/dev/null; then
            echo "  Format: SEMMSL SEMMNS SEMOPM SEMMNI"
            echo ""
        else
            echo "  Unable to read semaphore info"
            echo ""
        fi
    fi
}

# ==============================================================================
# Command: logs
# ==============================================================================

cmd_logs() {
    local service="$1"
    
    if [[ -z "$service" ]]; then
        log_info "Showing logs from all services (press Ctrl+C to stop)..."
        $PODMAN_COMPOSE_CMD logs -f
    else
        log_info "Showing logs from ${service} (press Ctrl+C to stop)..."
        podman logs -f "$service"
    fi
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    # Parse global flags
    local command=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            init|test|shell|clean|status|logs)
                command="$1"
                shift
                break
                ;;
            *)
                log_error "Unknown option: $1"
                echo ""
                print_usage
                exit 1
                ;;
        esac
    done
    
    # Check if command was provided
    if [[ -z "$command" ]]; then
        log_error "No command specified"
        echo ""
        print_usage
        exit 1
    fi
    
    # Route to appropriate command handler
    case $command in
        init)
            cmd_init "$@"
            ;;
        test)
            cmd_test "$@"
            ;;
        shell)
            cmd_shell "$@"
            ;;
        clean)
            cmd_clean "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        logs)
            cmd_logs "$@"
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            print_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
