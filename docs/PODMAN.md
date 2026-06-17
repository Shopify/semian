# Semian Development with Podman

This guide covers setting up and using Podman for Semian development as an alternative to Docker.

## Table of Contents

1. [Introduction](#introduction)
2. [Why Podman?](#why-podman)
3. [Prerequisites](#prerequisites)
4. [Quick Start](#quick-start)
5. [Detailed Command Reference](#detailed-command-reference)
6. [Architecture & Design](#architecture--design)
7. [Troubleshooting](#troubleshooting)
8. [Advanced Topics](#advanced-topics)
9. [Rootful Mode (Fallback)](#rootful-mode-fallback)
10. [FAQ](#faq)

## Introduction

Semian requires a Linux environment for bulkheading functionality (SysV semaphores). This guide shows how to set up a complete development environment using Podman, which is a Docker-compatible container engine.

**Key benefits of this setup:**
- Full Linux environment for SysV semaphores
- All required services (MySQL, Redis, PostgreSQL, Toxiproxy)
- Simple automation via helper script
- Rootless mode by default (better security)
- No Docker licensing concerns

## Why Podman?

Podman is an excellent alternative to Docker:

- **Docker-compatible**: Most Docker commands work with Podman
- **Rootless by default**: Better security model
- **Daemonless**: No background daemon required
- **Open source**: Apache 2.0 license, no licensing concerns
- **Drop-in replacement**: Uses same container images as Docker
- **Kubernetes-compatible**: Pod concept similar to K8s

## Prerequisites

### macOS Requirements

- **macOS 11.0+** (Big Sur or later)
- **Homebrew** package manager
- **At least 6GB free RAM** (4GB for Podman machine + 2GB for host)
- **At least 20GB free disk space**

### Linux Requirements

- **Modern Linux distribution** (Ubuntu 20.04+, Fedora 31+, etc.)
- **Kernel 4.18+** with support for:
  - User namespaces
  - Overlay filesystem
  - SysV semaphores
- **At least 4GB free RAM**

## Quick Start

### Installation

#### macOS

```bash
# Install Podman and podman-compose
brew install podman podman-compose

# Verify installation
podman --version
podman-compose --version
```

#### Linux (Ubuntu/Debian)

```bash
# Install Podman
sudo apt-get update
sudo apt-get install -y podman podman-compose

# Verify installation
podman --version
podman-compose --version
```

#### Linux (Fedora/RHEL)

```bash
# Install Podman
sudo dnf install -y podman podman-compose

# Verify installation
podman --version
podman-compose --version
```

### Initialize and Run

```bash
# Clone the repository (if not already done)
git clone https://github.com/Shopify/semian.git
cd semian

# Initialize everything (one command!)
./scripts/podman-setup.sh init
```

This will:
1. Check that Podman and podman-compose are installed
2. Initialize Podman machine (macOS only)
3. Pull required container images
4. Start all services (MySQL, Redis, PostgreSQL, Toxiproxy)
5. Wait for services to be healthy
6. Install Ruby dependencies
7. Build C extensions

### Run Tests

Tests run in a dedicated `semian-tests` container with the proper hostname and network configuration (matches CI behavior).

```bash
# Run all tests
./scripts/podman-setup.sh test

# Skip flaky tests
./scripts/podman-setup.sh test --skip-flaky

# Run with debugger (exposes port 12345)
./scripts/podman-setup.sh test --debug

# Run specific test pattern
./scripts/podman-setup.sh test --only mysql2
```

**Note:** The test container is ephemeral - it's created fresh for each test run and removed after completion. This ensures a clean environment matching CI/CD.

### Development Workflow

The development shell uses the `semian` container for interactive work.

```bash
# Get a shell in the container
./scripts/podman-setup.sh shell

# Inside the shell, you can:
bundle exec rake build             # Build C extensions
bundle exec ruby examples/foo.rb   # Run examples
irb -r ./lib/semian                # Interactive Ruby

# View status of all services
./scripts/podman-setup.sh status

# View logs from a specific service
./scripts/podman-setup.sh logs mysql

# View logs from all services
./scripts/podman-setup.sh logs
```

### Cleanup

```bash
# Stop and remove containers
./scripts/podman-setup.sh clean

# Also remove volumes
./scripts/podman-setup.sh clean --volumes

# Also stop Podman machine (macOS)
./scripts/podman-setup.sh clean --volumes --machine
```

## Development vs Test Containers

Semian uses a **two-container architecture** to separate development and testing workflows:

### Architecture Overview

| Container | Purpose | Hostname | Ports | Lifecycle | Created By |
|-----------|---------|----------|-------|-----------|------------|
| `semian` | Development shell, exploration | (random) | none | Persistent | `init` command |
| `semian-tests` | Running test suite | `http-server` | 31050, 31150, 12345 | Ephemeral | `test` command |

### The `semian` Container (Development)

**Purpose:** Interactive development and exploration

**Usage:**
```bash
./scripts/podman-setup.sh shell
```

**Use this container for:**
- Interactive development work
- Running irb/pry sessions
- Building C extensions
- Exploring code
- Running examples
- Quick experiments

**Important:** HTTP/network tests may fail in this shell because it lacks the required `http-server` hostname. For running tests, use the test command instead.

### The `semian-tests` Container (Testing)

**Purpose:** Running the complete test suite

**Usage:**
```bash
./scripts/podman-setup.sh test
```

**Key features:**
- Has hostname `http-server` (required for network tests)
- Exposes ports 31050 and 31150 (HTTP mock servers)
- Exposes port 12345 (debugger)
- Fresh environment each run (ephemeral)
- Matches CI/GitHub Actions configuration exactly

**Why separate containers?**

1. **Clean separation of concerns:** Development shell stays clean and simple
2. **Matches CI behavior:** Tests run identically locally and in CI
3. **Proper networking:** HTTP tests need specific hostname configuration
4. **No interference:** Test runs don't affect development environment
5. **Isolated state:** Each test run starts fresh

### Container Lifecycle

**Development container (`semian`):**
- Created once by `init` command
- Runs continuously until stopped
- Preserves state between shell sessions
- Manually managed

**Test container (`semian-tests`):**
- Created automatically by `test` command
- Runs only during test execution
- Removed immediately after tests complete (`run --rm`)
- No manual management needed

### When to Use Which

```bash
# ✅ Correct: Run tests via test command
./scripts/podman-setup.sh test

# ✅ Correct: Development work in shell
./scripts/podman-setup.sh shell
$ bundle exec rake build
$ irb -r ./lib/semian

# ❌ Wrong: Don't run full test suite from shell
./scripts/podman-setup.sh shell
$ bundle exec rake test  # This will fail for HTTP/network tests!
```

## Detailed Command Reference

### `init` - Initialize Environment

```bash
./scripts/podman-setup.sh init [--verbose]
```

Initializes the complete development environment:
- Verifies Podman and podman-compose are installed
- Checks versions and warns if outdated
- Initializes Podman machine with 4GB RAM and 2 CPUs (macOS)
- Pulls all required container images
- Starts all services
- Waits for services to be healthy
- Installs Ruby dependencies
- Builds C extensions

**Options:**
- `--verbose`: Show detailed output from all operations

**Example:**
```bash
./scripts/podman-setup.sh init --verbose
```

### `test` - Run Tests

```bash
./scripts/podman-setup.sh test [options]
```

Runs the Semian test suite in a dedicated `semian-tests` container.

**Container Details:**
- Uses `semian-tests` container (not the development `semian` container)
- Has hostname `http-server` for network tests
- Exposes ports 31050, 31150 (HTTP mock servers) and 12345 (debugger)
- Ephemeral: Created fresh for each run, removed after completion
- Matches CI/GitHub Actions environment exactly

**Options:**
- `--skip-flaky`: Skip tests marked as flaky
- `--debug`: Run with debugger support (exposes port 12345)
- `--only <pattern>`: Run only tests matching pattern
- `--verbose`: Show detailed output

**Examples:**
```bash
# Run all tests
./scripts/podman-setup.sh test

# Skip flaky tests
./scripts/podman-setup.sh test --skip-flaky

# Run with debugger
./scripts/podman-setup.sh test --debug

# Run only MySQL2 adapter tests
./scripts/podman-setup.sh test --only mysql2

# Run only resource tests (non-network)
./scripts/podman-setup.sh test --only resource

# Run only net_http tests (network tests)
./scripts/podman-setup.sh test --only net_http

# Verbose output, skip flaky
./scripts/podman-setup.sh test --skip-flaky --verbose
```

**Why a separate test container?**

Tests require specific network configuration:
- Hostname `http-server` for network/HTTP tests to connect
- Ports 31050 and 31150 for mock HTTP servers
- Clean environment for reproducible test runs

This ensures tests run identically locally and in CI.

### `shell` - Development Shell

```bash
./scripts/podman-setup.sh shell [--verbose]
```

Opens an interactive bash shell inside the `semian` development container.

**Features:**
- Automatically runs `bundle install` if needed
- Full access to all services
- Can build C extensions, run examples, use irb/pry
- Changes to code on host are immediately reflected

**⚠️ Important:** 
The shell displays a warning that HTTP/network tests may fail due to hostname requirements. For running the full test suite, use `./scripts/podman-setup.sh test` instead.

You can run non-network tests (like resource tests) from the shell, but HTTP tests require the dedicated test container.

**Example:**
```bash
./scripts/podman-setup.sh shell

# Inside the shell:
$ bundle exec rake test:semian
$ bundle exec ruby examples/net_http/simple.rb
$ irb -r ./lib/semian
```

### `status` - Show Status

```bash
./scripts/podman-setup.sh status [--verbose]
```

Shows the status of:
- Podman machine (macOS)
- All containers
- Service health
- SysV semaphore configuration

**Example output:**
```
Podman Machine:
NAME                     VM TYPE     CREATED      LAST UP            CPUS        MEMORY      DISK SIZE
podman-machine-default*  qemu        2 hours ago  Currently running  2           4GB         100GB

Containers:
NAMES             STATUS                   PORTS
semian            Up 30 minutes           
mysql             Up 30 minutes           
redis             Up 30 minutes           
postgres          Up 30 minutes           
toxiproxy         Up 30 minutes           

Service Health:
  MySQL:      ✓ Healthy
  Redis:      ✓ Healthy
  PostgreSQL: ✓ Healthy

SysV Semaphores:
250     32000   32      128
  Format: SEMMSL SEMMNS SEMOPM SEMMNI
```

### `logs` - View Logs

```bash
./scripts/podman-setup.sh logs [service]
```

Tails logs from services. Press Ctrl+C to stop.

**Examples:**
```bash
# View all service logs
./scripts/podman-setup.sh logs

# View MySQL logs only
./scripts/podman-setup.sh logs mysql

# View Redis logs only
./scripts/podman-setup.sh logs redis
```

### `clean` - Cleanup

```bash
./scripts/podman-setup.sh clean [options]
```

Cleans up containers and optionally volumes and Podman machine.

**Options:**
- `--volumes`: Also remove volumes (data will be lost)
- `--machine`: Also stop Podman machine (macOS)
- `--verbose`: Show detailed output

**Examples:**
```bash
# Just remove containers
./scripts/podman-setup.sh clean

# Remove containers and volumes
./scripts/podman-setup.sh clean --volumes

# Remove everything including stopping machine
./scripts/podman-setup.sh clean --volumes --machine
```

## Architecture & Design

### Service Architecture

```
┌─────────────────────────────────────────────────────┐
│ Podman Machine (macOS) / Host (Linux)              │
│                                                     │
│  ┌──────────────────────────────────────────────┐ │
│  │ Semian Container (Development)               │ │
│  │  - Ruby 3.4.3                                │ │
│  │  - Bundler + Dependencies                    │ │
│  │  - C Extensions Built                        │ │
│  │  - Volume mount: ./:/workspace               │ │
│  └─────────────┬────────────────────────────────┘ │
│                │ Shared IPC Namespace             │
│                │ (Critical for SysV semaphores)   │
│  ┌─────────────┴────────────────────────────────┐ │
│  │ Supporting Services                          │ │
│  │  ┌─────────┐ ┌─────────┐ ┌──────────┐       │ │
│  │  │  MySQL  │ │  Redis  │ │ Postgres │       │ │
│  │  │  :9.3   │ │ :latest │ │   :15    │       │ │
│  │  └─────────┘ └─────────┘ └──────────┘       │ │
│  │  ┌──────────────┐                            │ │
│  │  │  Toxiproxy   │ (Resiliency Testing)       │ │
│  │  │    :2.12.0   │                            │ │
│  │  └──────────────┘                            │ │
│  └───────────────────────────────────────────────┘ │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### Key Design Decisions

#### 1. IPC Namespace Sharing

SysV semaphores require shared IPC namespace. This is configured with:
```yaml
ipc: "shareable"
```

All containers can access the same semaphore set, which is critical for bulkhead functionality.

#### 2. Rootless Mode with UID Mapping

Using `userns_mode: "keep-id"` ensures:
- Container processes run as your user ID
- Files created in volumes have correct ownership
- Better security than running as root

#### 3. Volume Mount with SELinux Support

Using `./:/workspace:Z` ensures:
- Files are accessible in both rootless and rootful modes
- SELinux contexts are properly set (on systems with SELinux)
- Works transparently on macOS

#### 4. Privileged Mode for Debugging

`privileged: true` and capabilities like `SYS_PTRACE` enable:
- Debugger support (gdb, lldb)
- SysV semaphore operations
- Performance profiling tools

### Network Configuration

All services are on the same compose network, so they can communicate using service names:
- `mysql` - MySQL server
- `redis` - Redis server
- `postgres` - PostgreSQL server
- `toxiproxy` - Toxiproxy server

Example: Connect to MySQL from Semian container:
```bash
mysql -h mysql -uroot -proot
```

### SysV Semaphores

Semian uses SysV semaphores for bulkheading. These are kernel-level primitives that:
- Provide process-wide synchronization
- Survive process crashes (with SEM_UNDO)
- Have system-wide limits

Check semaphore configuration:
```bash
./scripts/podman-setup.sh shell
cat /proc/sys/kernel/sem
```

Output format: `SEMMSL SEMMNS SEMOPM SEMMNI`
- **SEMMSL**: Max semaphores per array
- **SEMMNS**: System-wide semaphore limit
- **SEMOPM**: Max operations per semop call
- **SEMMNI**: Max semaphore arrays

## Troubleshooting

### Podman Machine Issues (macOS)

#### Problem: "podman machine is not running"

**Error:**
```
Error: cannot connect to Podman. Please verify your connection to the Linux system
```

**Solution:**
```bash
# Check machine status
podman machine list

# Start the machine
podman machine start

# Or use the script
./scripts/podman-setup.sh init
```

#### Problem: Podman machine won't start

**Error:**
```
Error: qemu exited unexpectedly
```

**Solution:**
```bash
# Remove and recreate the machine
podman machine stop
podman machine rm

# Re-initialize
./scripts/podman-setup.sh init
```

### Service Connection Issues

#### Problem: "Connection refused" errors

**Symptoms:**
- Tests fail with connection errors
- Can't connect to MySQL/Redis/Postgres

**Solution:**
```bash
# Check service status
./scripts/podman-setup.sh status

# Check specific service logs
./scripts/podman-setup.sh logs mysql

# Restart services
./scripts/podman-setup.sh clean
./scripts/podman-setup.sh init
```

#### Problem: MySQL "Access denied for user"

**Error:**
```
Access denied for user 'root'@'172.x.x.x' (using password: YES)
```

**Solution:**
This usually means MySQL hasn't fully initialized. Wait a bit longer:
```bash
# Wait for MySQL manually
podman exec mysql mysqladmin ping -h localhost -uroot -proot

# Or restart services
./scripts/podman-setup.sh clean
./scripts/podman-setup.sh init
```

#### Problem: "Name or service not known" for http-server

**Error:**
```
Socket::ResolutionError: Failed to open TCP connection to http-server:31050 
(getaddrinfo(3): Name or service not known)
```

Or:
```
Errno::EADDRINUSE: Address already in use - bind(2) for "0.0.0.0" port 31050
```

**Cause:** Tests are being run in the wrong container (development `semian` container instead of the `semian-tests` container).

**Why this happens:**
- HTTP/network tests need hostname `http-server` to connect to mock servers
- The development `semian` container doesn't have this hostname
- The `semian-tests` container has the proper configuration

**Solution:**

Always use the `test` command, which automatically uses the correct container:

```bash
# ✅ Correct - Uses test container with proper hostname
./scripts/podman-setup.sh test

# ✅ Correct - Can specify patterns
./scripts/podman-setup.sh test --only net_http

# ❌ Wrong - Running tests manually in shell
./scripts/podman-setup.sh shell
$ bundle exec rake test  # This will fail for HTTP tests!
```

**If you need to run specific non-network tests in the shell:**

```bash
./scripts/podman-setup.sh shell

# These work (no network requirements):
$ bundle exec ruby -Ilib:test test/resource_test.rb
$ bundle exec rake build

# These fail (need http-server hostname):
$ bundle exec ruby -Ilib:test test/adapters/net_http_test.rb  # ❌ Will fail
```

**Key takeaway:** Always use `./scripts/podman-setup.sh test` for running tests. The test container is specifically configured for this purpose.

### SysV Semaphore Issues

#### Problem: "Operation not permitted" on semaphore operations

**Error:**
```
Errno::EPERM: Operation not permitted - semget
```

**Possible causes:**
1. Insufficient capabilities in rootless mode
2. IPC namespace not properly shared
3. System semaphore limits exceeded

**Solutions:**

**Option 1: Check IPC namespace**
```bash
# Verify IPC sharing is configured
grep "ipc:" podman-compose.yml
```

**Option 2: Check system limits**
```bash
./scripts/podman-setup.sh shell
cat /proc/sys/kernel/sem

# Should show something like: 250 32000 32 128
```

**Option 3: Switch to rootful mode** (see [Rootful Mode](#rootful-mode-fallback))

#### Problem: "No space left on device" for semaphores

**Error:**
```
Errno::ENOSPC: No space left on device - semget
```

**Cause:** System semaphore limit reached.

**Solution:**
Clean up existing semaphores:
```bash
./scripts/podman-setup.sh shell

# List semaphores
ipcs -s

# Remove specific semaphore (if you know the ID)
ipcrm -s <semid>

# Or remove all (use with caution!)
ipcs -s | grep $(whoami) | awk '{print $2}' | xargs -r ipcrm -s
```

### Volume Mount Issues

#### Problem: Permission denied accessing files

**Error:**
```
Permission denied @ rb_sysopen - /workspace/Gemfile.lock
```

**Cause:** UID/GID mismatch between host and container.

**Solution:**
The `userns_mode: "keep-id"` should handle this, but if not:

```bash
# Check file ownership
ls -la Gemfile.lock

# Fix ownership (on host)
sudo chown $(id -u):$(id -g) Gemfile.lock

# Or recreate the container
./scripts/podman-setup.sh clean
./scripts/podman-setup.sh init
```

### Port Conflicts

#### Problem: "address already in use"

**Error:**
```
Error: cannot listen on the TCP port: address already in use
```

**Solution:**
```bash
# Find what's using the port (12345 for debugger)
lsof -i :12345

# Kill the process or stop conflicting service
kill <PID>

# Restart
./scripts/podman-setup.sh clean
./scripts/podman-setup.sh init
```

### Test Issues

#### Problem: Tests hang indefinitely

**Symptoms:**
- Tests start but never complete
- No error messages

**Possible causes:**
1. Deadlock in semaphore operations
2. Service not responding
3. Network connectivity issue

**Solutions:**

**Check service health:**
```bash
./scripts/podman-setup.sh status
```

**Check for deadlocks:**
```bash
./scripts/podman-setup.sh shell
ipcs -s
# Look for semaphores with unusual values
```

**Run tests with timeout:**
```bash
timeout 300 ./scripts/podman-setup.sh test
```

**Clean restart:**
```bash
./scripts/podman-setup.sh clean --volumes
./scripts/podman-setup.sh init
./scripts/podman-setup.sh test
```

### General Debugging

#### Enable verbose output

```bash
./scripts/podman-setup.sh --verbose <command>
```

#### Check container logs

```bash
# All services
./scripts/podman-setup.sh logs

# Specific service
podman logs semian
podman logs mysql
```

#### Inspect container

```bash
# Get detailed container info
podman inspect semian

# Check environment variables
podman exec semian env

# Check running processes
podman top semian
```

## Advanced Topics

### Running Specific Test Files

```bash
# Get a shell
./scripts/podman-setup.sh shell

# Run specific test file
bundle exec ruby -Ilib:test test/resource_test.rb

# Run with minitest options
bundle exec ruby -Ilib:test test/resource_test.rb --verbose --name test_acquire
```

### Using Podman Desktop (GUI)

[Podman Desktop](https://podman-desktop.io/) provides a GUI for managing containers:

```bash
brew install podman-desktop
```

Features:
- Visual container management
- Image registry browser
- Volume management
- Log viewer
- Resource monitoring

### Debugging with VS Code

You can attach VS Code to a running container:

1. Install "Dev Containers" extension
2. Start the environment: `./scripts/podman-setup.sh init`
3. In VS Code: Command Palette → "Dev Containers: Attach to Running Container"
4. Select "semian"

Or use the Ruby debugger with the test command:
```bash
./scripts/podman-setup.sh test --debug

# In another terminal or VS Code, connect to localhost:12345
```

### Inspecting Semaphores

```bash
./scripts/podman-setup.sh shell

# List all semaphores
ipcs -s

# Get semaphore key for a resource
irb -r ./lib/semian
resource = Semian::Resource.new(:test_resource, tickets: 5)
puts "0x%x" % resource.key

# Inspect specific semaphore set
ipcs -si <semid>
```

### Performance Tuning

#### Increase Podman machine resources (macOS)

```bash
# Stop current machine
podman machine stop

# Recreate with more resources
podman machine rm
podman machine init --memory 8192 --cpus 4 --disk-size 100

# Start and re-initialize
podman machine start
./scripts/podman-setup.sh init
```

#### Adjust container resources

Edit `podman-compose.yml` and add:
```yaml
services:
  semian:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 2G
```

### Customizing Configuration

#### Use environment variables

Create a `.env` file in the project root:
```bash
# .env
SKIP_FLAKY_TESTS=true
DEBUG=true
```

The test runner will automatically load this file.

#### Override compose configuration

Create `podman-compose.override.yml`:
```yaml
version: "3.7"
services:
  semian:
    environment:
      - CUSTOM_VAR=value
```

This file is automatically loaded by podman-compose and overrides settings.

## Rootful Mode (Fallback)

If you encounter issues with SysV semaphores in rootless mode, you can switch to rootful mode.

### ⚠️ Security Warning

Rootful mode runs containers as root, which is less secure. Only use this if rootless mode doesn't work.

### When to Use Rootful Mode

Switch to rootful if you see:
- `Operation not permitted` errors on semaphore operations
- Bulkhead tests consistently failing
- `semget`/`semctl` system call errors

### Switching to Rootful (macOS)

```bash
# Stop and remove current machine
podman machine stop
podman machine rm

# Create new rootful machine
podman machine init --rootful semian-rootful --memory 4096 --cpus 2

# Start machine
podman machine start semian-rootful

# Set as default (optional)
podman system connection default semian-rootful

# Re-initialize environment
./scripts/podman-setup.sh init
```

### Switching to Rootful (Linux)

On Linux, use `sudo` with Podman commands:

```bash
# Clean up rootless containers
./scripts/podman-setup.sh clean

# Run as root
sudo podman-compose -f podman-compose.yml up -d

# Get root shell
sudo podman exec -it semian bash

# Run tests as root
sudo podman exec semian bash -c "cd /workspace && bundle exec rake test"
```

**Note:** This is not recommended for Linux. Consider fixing permissions instead.

### Switching Back to Rootless (macOS)

```bash
# Stop rootful machine
podman machine stop semian-rootful

# Remove it
podman machine rm semian-rootful

# Recreate default rootless machine
podman machine init --memory 4096 --cpus 2

# Start and re-initialize
podman machine start
./scripts/podman-setup.sh init
```

## FAQ

### Can I use both Docker and Podman?

Yes! The Docker and Podman setups are completely separate:
- Docker uses `.devcontainer/docker-compose.yml`
- Podman uses `podman-compose.yml`

They don't interfere with each other.

### How do I switch between Docker and Podman?

Just use the appropriate tool:
```bash
# Docker
docker-compose -f .devcontainer/docker-compose.yml up -d

# Podman
./scripts/podman-setup.sh init
```

### Will this work on Linux?

Yes! Podman actually works better on Linux since it's native (no VM needed).

Linux-specific benefits:
- Faster performance (no virtualization)
- Direct SysV semaphore access
- Lower resource overhead

### What about CI/CD?

The GitHub Actions workflows use Docker, which is fine. This Podman setup is for local development.

If you want to use Podman in CI:
- Use native Linux runners (Ubuntu)
- Install Podman: `apt-get install podman`
- Use the test command: `./scripts/podman-setup.sh test`

### Can I run tests from the development shell?

**Short answer:** Use `./scripts/podman-setup.sh test` instead.

**Long answer:** Some tests will work in the development shell, but HTTP/network tests will fail due to hostname requirements.

**What works in the shell:**
```bash
./scripts/podman-setup.sh shell

# ✅ These work (non-network tests)
$ bundle exec ruby -Ilib:test test/resource_test.rb
$ bundle exec ruby -Ilib:test test/simple_integer_test.rb
$ bundle exec rake build

# ❌ These fail (need http-server hostname)
$ bundle exec rake test  # Full suite fails
$ bundle exec ruby -Ilib:test test/adapters/net_http_test.rb
```

**Why?**

The development `semian` container lacks:
- Hostname `http-server` (tests try to connect to `http-server:31050`)
- Published ports 31050 and 31150 (for HTTP mock servers)

The `semian-tests` container has the proper configuration for all tests.

**Best practice:** 

Always use the test command for running tests:
```bash
# Full suite
./scripts/podman-setup.sh test

# Specific tests
./scripts/podman-setup.sh test --only net_http
./scripts/podman-setup.sh test --only resource
```

Use the shell for development work:
```bash
./scripts/podman-setup.sh shell

# Development tasks
$ bundle exec rake build
$ irb -r ./lib/semian
$ ruby examples/net_http/simple.rb
```

### Can I use Podman without podman-compose?

Yes, but it's more complex. You'd need to:
1. Create a pod: `podman pod create --name semian-dev`
2. Start each container in the pod
3. Manage networking manually

The helper script makes this easier with podman-compose.

### How much disk space does this use?

Approximately:
- Podman machine (macOS): ~10GB
- Container images: ~2-3GB
- Volumes: ~1GB
- **Total: ~15GB**

### How much memory does this use?

- Podman machine: 4GB (configurable)
- Containers: ~1-2GB combined
- **Total: ~5-6GB**

### Is Podman slower than Docker?

Performance is similar:
- On macOS: Both use VMs, comparable speed
- On Linux: Podman is slightly faster (no daemon overhead)

### Can I use rootless mode on Linux?

Yes, and it's recommended! Rootless mode is actually easier on Linux than macOS.

Requirements:
- User namespaces enabled (`sysctl kernel.unprivileged_userns_clone`)
- Subuids/subgids configured (`/etc/subuid`, `/etc/subgid`)

Most modern distros have this by default.

### What if I get "command not found: podman-compose"?

Install it:
```bash
# macOS
brew install podman-compose

# Linux with pip
pip3 install podman-compose

# Or use podman's built-in support (experimental)
alias podman-compose='podman compose'
```

### Where are containers stored?

- **macOS**: Inside Podman machine VM at `~/.local/share/containers/`
- **Linux**: `~/.local/share/containers/storage/` (rootless) or `/var/lib/containers/storage/` (rootful)

### How do I completely uninstall everything?

```bash
# Clean up containers and volumes
./scripts/podman-setup.sh clean --volumes --machine

# Remove Podman machine (macOS)
podman machine rm

# Uninstall Podman
brew uninstall podman podman-compose  # macOS
sudo apt-get remove podman            # Linux
```

### Can I contribute improvements to this setup?

Absolutely! Please open a PR with:
- Bug fixes
- Documentation improvements
- New helper script features
- Performance optimizations

---

## Additional Resources

- [Podman Documentation](https://docs.podman.io/)
- [Podman Desktop](https://podman-desktop.io/)
- [Podman Compose GitHub](https://github.com/containers/podman-compose)
- [Main Semian README](../README.md)
- [Semian Contributing Guide](../CONTRIBUTING.md) (if exists)

## Getting Help

If you encounter issues:

1. Check this troubleshooting guide
2. Run with `--verbose` flag for details
3. Check container logs: `./scripts/podman-setup.sh logs`
4. Open an issue on GitHub with:
   - Your OS and version
   - Podman version (`podman --version`)
   - podman-compose version (`podman-compose --version`)
   - Full error message
   - Output of `./scripts/podman-setup.sh status`
