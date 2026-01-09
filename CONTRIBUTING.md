# Contributing to nginx-optimizer

Thank you for considering contributing to nginx-optimizer! This document provides guidelines for contributing to the project.

## Table of Contents

- [Development Environment Setup](#development-environment-setup)
- [Code Style Guidelines](#code-style-guidelines)
- [Running Tests](#running-tests)
- [Pull Request Process](#pull-request-process)
- [Commit Message Format](#commit-message-format)
- [Adding New Features](#adding-new-features)
- [Issue Reporting](#issue-reporting)
- [Code Review Process](#code-review-process)

## Development Environment Setup

### Prerequisites

nginx-optimizer is a pure bash project with minimal dependencies:

- **Bash 3.2+** (default on macOS, compatible with Linux)
- **Git** (for version control)
- **shellcheck** (optional but recommended for linting)

### Clone the Repository

```bash
git clone https://github.com/MarcinDudekDev/nginx-optimizer.git
cd nginx-optimizer
```

### Make Executable

```bash
chmod +x nginx-optimizer.sh
```

### Install shellcheck (Optional but Recommended)

**macOS:**
```bash
brew install shellcheck
```

**Ubuntu/Debian:**
```bash
sudo apt-get install shellcheck
```

### No Build Step Required

Since this is a pure bash project, there's no compilation or build step. You can run the script directly:

```bash
./nginx-optimizer.sh help
```

## Code Style Guidelines

### Bash Version Compatibility

**CRITICAL**: All code must be compatible with **Bash 3.2+** (macOS default).

**Forbidden:**
- `declare -A` (associative arrays - bash 4+ only)
- `&>>` redirect operator
- `|&` pipe operator

**Allowed:**
- Indexed arrays: `arr=("one" "two")`
- Standard redirects: `2>&1`
- All bash 3.2 features

### Portability Requirements

**No GNU-only commands:**
- ❌ `find -printf` (use `find -print0 | xargs -0` instead)
- ❌ `flock` (Linux-only, not available on macOS)
- ❌ `readlink -f` (use `cd "$(dirname "$path")" && pwd` instead)

**Use portable alternatives:**
- ✅ `find -print` or `find -print0`
- ✅ Cross-platform locking mechanisms
- ✅ BSD-compatible commands

### Shellcheck Compliance

All code must pass shellcheck with **severity=error**:

```bash
shellcheck --severity=error nginx-optimizer.sh nginx-optimizer-lib/*.sh
```

Warnings are informational but should be minimized. Use `# shellcheck disable=SCXXXX` with a comment explaining why if needed.

### Script Structure

**Every script must start with:**

```bash
#!/bin/bash

set -euo pipefail
```

This ensures:
- `set -e`: Exit on error
- `set -u`: Exit on undefined variable
- `set -o pipefail`: Catch errors in pipes

### Naming Conventions

**Functions:** `snake_case`
```bash
acquire_lock() {
    # implementation
}

log_info() {
    # implementation
}
```

**Variables:**
- **Constants/Globals:** `UPPER_CASE`
  ```bash
  VERSION="0.9.0-beta"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ```

- **Local variables:** `lower_case`
  ```bash
  local site_name="example.com"
  local config_path="/etc/nginx"
  ```

### Variable Quoting

**ALWAYS quote variables** to prevent word splitting and globbing:

```bash
# ✅ CORRECT
if [[ -f "$config_file" ]]; then
    cp "$config_file" "$backup_dir/"
fi

# ❌ WRONG
if [[ -f $config_file ]]; then
    cp $config_file $backup_dir/
fi
```

### Conditional Tests

Use `[[ ]]` for tests (bash builtin), not `[ ]` (POSIX test):

```bash
# ✅ CORRECT
if [[ "$var" == "value" ]]; then
    echo "match"
fi

if [[ -f "$file" && -r "$file" ]]; then
    cat "$file"
fi

# ❌ WRONG
if [ "$var" == "value" ]; then
    echo "match"
fi
```

### Error Handling

Check command success before using results:

```bash
# ✅ CORRECT
if nginx -t 2>/dev/null; then
    log_success "Config valid"
else
    log_error "Config invalid"
    return 1
fi

# Use || true for commands that may fail safely
count=$(grep -c "pattern" file || true)
```

### Comments and Documentation

```bash
# Single-line comment for brief explanations

################################################################################
# Section headers for major blocks
################################################################################

# Multi-line comments for complex logic:
# 1. First step explanation
# 2. Second step explanation
# 3. Final step
```

### Function Structure

```bash
function_name() {
    local param1="$1"
    local param2="${2:-default}"

    # Validate inputs
    if [[ -z "$param1" ]]; then
        log_error "param1 is required"
        return 1
    fi

    # Implementation
    # ...

    return 0
}
```

## Running Tests

### Run Full Test Suite

```bash
./tests/run-tests.sh
```

The test suite includes:
1. **Static Analysis**: Shellcheck validation
2. **Bash Compatibility**: Syntax checks on bash 3.2+
3. **Portability**: Detection of GNU-only commands
4. **Functional Tests**: Command execution tests
5. **Dry-Run Tests**: Safety validation
6. **Idempotency Tests**: Consistent behavior verification

### Run Individual Checks

**Shellcheck only:**
```bash
shellcheck --severity=error nginx-optimizer.sh nginx-optimizer-lib/*.sh
```

**Syntax check:**
```bash
bash -n nginx-optimizer.sh
```

**Test a specific command:**
```bash
./nginx-optimizer.sh --version
./nginx-optimizer.sh help
./nginx-optimizer.sh optimize --dry-run
```

### CI Requirements

All PRs must pass CI on:
- **ubuntu-latest** (Linux)
- **macos-latest** (macOS)

CI runs:
- Shellcheck (errors and warnings)
- Syntax validation
- Full test suite
- Portability checks

## Pull Request Process

### Before You Submit

1. **Fork** the repository
2. **Create a feature branch:**
   ```bash
   git checkout -b feature/your-feature-name
   ```
   or
   ```bash
   git checkout -b fix/bug-description
   ```

3. **Make your changes** with proper tests
4. **Run tests locally:**
   ```bash
   ./tests/run-tests.sh
   ```

5. **Run shellcheck:**
   ```bash
   shellcheck --severity=error nginx-optimizer.sh nginx-optimizer-lib/*.sh
   ```

6. **Test on your platform** (Linux or macOS)

### Submitting the PR

1. **Push to your fork:**
   ```bash
   git push origin feature/your-feature-name
   ```

2. **Create Pull Request** against the `main` branch

3. **Fill in PR template** with:
   - Description of changes
   - Related issue number (if applicable)
   - Testing performed
   - Screenshots (if UI changes)

4. **Wait for CI** to pass (both ubuntu-latest and macos-latest)

5. **Address review feedback** if requested

### PR Checklist

- [ ] Tests added/updated
- [ ] All tests pass locally
- [ ] Shellcheck passes with no errors
- [ ] Code follows style guidelines
- [ ] Commit messages follow conventional format
- [ ] Documentation updated (if needed)
- [ ] No GNU-only or bash 4+ features used

## Commit Message Format

We follow **Conventional Commits** specification:

```
type(scope): description

[optional body]

[optional footer]
```

### Types

- **feat**: New feature
- **fix**: Bug fix
- **docs**: Documentation changes
- **style**: Code style/formatting (no logic change)
- **refactor**: Code restructuring (no behavior change)
- **test**: Adding or updating tests
- **chore**: Maintenance tasks, dependencies

### Scopes

Common scopes in this project:
- `http3`: HTTP/3 (QUIC) feature
- `fastcgi`: FastCGI cache feature
- `redis`: Redis cache feature
- `brotli`: Brotli compression
- `security`: Security headers and hardening
- `wordpress`: WordPress-specific features
- `opcache`: PHP OpCache optimization
- `backup`: Backup/rollback functionality
- `cli`: Command-line interface
- `tests`: Test suite
- `ci`: CI/CD pipeline

### Examples

```
feat(http3): add QUIC 0-RTT support

Implements 0-RTT resumption for HTTP/3 connections to reduce
latency for returning visitors.

Closes #42
```

```
fix(backup): handle spaces in file paths

Previously failed when nginx config directory contained spaces.
Now properly quotes all paths.

Fixes #38
```

```
docs(readme): update installation instructions

Clarifies bash version requirement and adds troubleshooting
section for macOS users.
```

```
refactor(detector): simplify nginx instance detection

Consolidates duplicate detection logic into single function.
No behavior change.
```

```
test(portability): add GNU command detection tests

Ensures no find -printf or declare -A slips through.
```

## Adding New Features

### Structure

1. **Add library file** to `nginx-optimizer-lib/`:
   ```
   nginx-optimizer-lib/
   └── new-feature.sh
   ```

2. **Add template** (if needed) to `nginx-optimizer-templates/`:
   ```
   nginx-optimizer-templates/
   └── new-feature.conf
   ```

3. **Register in main script**:
   Edit `nginx-optimizer.sh` and update `source_libraries()`:
   ```bash
   source_libraries() {
       source "${LIB_DIR}/detector.sh"
       source "${LIB_DIR}/backup.sh"
       source "${LIB_DIR}/new-feature.sh"  # Add here
       # ...
   }
   ```

4. **Add command handler** (if new command):
   ```bash
   cmd_new_feature() {
       log_info "Running new feature..."
       # Implementation
   }
   ```

5. **Update help text** in `show_help()`:
   ```bash
   show_help() {
       cat << EOF
   COMMANDS:
     analyze [site]       Show optimization status
     new-feature [site]   Description of new feature
     # ...
   EOF
   }
   ```

6. **Add tests** to `tests/run-tests.sh`:
   ```bash
   # Test: New feature command
   new_feature_output=$("${OPTIMIZER}" new-feature 2>&1 || true)
   if echo "$new_feature_output" | grep -q "expected output"; then
       log_pass "new-feature command works"
   else
       log_fail "new-feature command failed"
   fi
   ```

### Feature Implementation Pattern

```bash
# nginx-optimizer-lib/new-feature.sh

apply_new_feature() {
    local site_name="$1"
    local config_path="$2"

    log_info "Applying new feature to ${site_name}..."

    # Validation
    if [[ ! -d "$config_path" ]]; then
        log_error "Config path not found: ${config_path}"
        return 1
    fi

    # Dry-run check
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would apply new feature"
        return 0
    fi

    # Implementation
    local template="${TEMPLATE_DIR}/new-feature.conf"
    local target="${config_path}/new-feature.conf"

    if [[ -f "$template" ]]; then
        cp "$template" "$target"
        log_success "New feature applied"
    else
        log_error "Template not found: ${template}"
        return 1
    fi

    return 0
}

detect_new_feature() {
    local config_path="$1"

    if [[ -f "${config_path}/new-feature.conf" ]]; then
        echo "enabled"
    else
        echo "disabled"
    fi
}
```

## Issue Reporting

### Before Opening an Issue

1. **Search existing issues** to avoid duplicates
2. **Check logs** in `~/.nginx-optimizer/logs/`
3. **Try dry-run mode**: `nginx-optimizer optimize --dry-run`
4. **Test nginx config**: `nginx -t`

### Issue Template

When reporting bugs, include:

**System Information:**
- OS: [e.g., Ubuntu 22.04, macOS 14.0]
- Bash version: `bash --version`
- nginx version: `nginx -V`
- nginx-optimizer version: `./nginx-optimizer.sh --version`

**Steps to Reproduce:**
1. Step one
2. Step two
3. Step three

**Expected Behavior:**
What you expected to happen

**Actual Behavior:**
What actually happened

**Logs:**
```
Paste relevant logs from ~/.nginx-optimizer/logs/
```

**Additional Context:**
Any other relevant information

## Code Review Process

### What Reviewers Look For

1. **Correctness**: Does it solve the problem?
2. **Testing**: Are there tests? Do they pass?
3. **Style**: Does it follow guidelines?
4. **Portability**: Works on Linux and macOS?
5. **Compatibility**: Bash 3.2 compatible?
6. **Documentation**: Is it documented?

### Review Timeline

- Initial review: Within 1-3 days
- Follow-up reviews: Within 1-2 days
- Merging: After approval and CI pass

### Getting Help

If you need help with your contribution:

1. **Comment on your PR** with specific questions
2. **Open a discussion** in GitHub Discussions
3. **Reference related issues** for context

## Additional Resources

- [Bash Guide](https://mywiki.wooledge.org/BashGuide)
- [Shellcheck Wiki](https://github.com/koalaman/shellcheck/wiki)
- [Conventional Commits](https://www.conventionalcommits.org/)
- [NGINX Documentation](https://nginx.org/en/docs/)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to nginx-optimizer! Your efforts help make NGINX optimization accessible to everyone.
