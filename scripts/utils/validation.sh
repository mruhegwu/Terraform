#!/usr/bin/env bash
# Input validation helpers for deployment scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=logging.sh
source "${SCRIPT_DIR}/logging.sh"

# Validate that a value is a recognised environment name
validate_environment() {
  local env="$1"
  local valid_envs=("dev" "staging" "prod" "production")
  for valid in "${valid_envs[@]}"; do
    if [ "$env" = "$valid" ]; then
      return 0
    fi
  done
  log_error "Invalid environment '${env}'. Must be one of: ${valid_envs[*]}"
  return 1
}

# Normalise prod/production -> prod
normalize_environment() {
  local env="$1"
  if [ "$env" = "production" ]; then
    echo "prod"
  else
    echo "$env"
  fi
}

# Validate a required environment variable is set and non-empty
validate_env_var() {
  local var_name="$1"
  local value="${!var_name:-}"
  if [ -z "$value" ]; then
    log_error "Required environment variable '${var_name}' is not set."
    return 1
  fi
  return 0
}

# Validate multiple required environment variables
validate_required_vars() {
  local failed=0
  for var in "$@"; do
    validate_env_var "$var" || failed=1
  done
  return $failed
}

# Validate that a command exists in PATH
validate_command() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    log_error "Required command '${cmd}' not found in PATH."
    return 1
  fi
  return 0
}

# Validate multiple required commands
validate_required_commands() {
  local failed=0
  for cmd in "$@"; do
    validate_command "$cmd" || failed=1
  done
  return $failed
}

# Validate a file exists and is readable
validate_file() {
  local file_path="$1"
  if [ ! -f "$file_path" ]; then
    log_error "Required file not found: ${file_path}"
    return 1
  fi
  if [ ! -r "$file_path" ]; then
    log_error "File is not readable: ${file_path}"
    return 1
  fi
  return 0
}

# Validate a directory exists
validate_directory() {
  local dir_path="$1"
  if [ ! -d "$dir_path" ]; then
    log_error "Required directory not found: ${dir_path}"
    return 1
  fi
  return 0
}

# Validate a string is not empty
validate_not_empty() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    log_error "${name} must not be empty."
    return 1
  fi
  return 0
}

# Validate a value matches a regex pattern
validate_pattern() {
  local name="$1"
  local value="$2"
  local pattern="$3"
  if [[ ! "$value" =~ $pattern ]]; then
    log_error "${name} '${value}' does not match required pattern: ${pattern}"
    return 1
  fi
  return 0
}

# Prompt user for confirmation (returns 0 for yes, 1 for no)
confirm_action() {
  local prompt="${1:-Are you sure?}"
  local default="${2:-n}"

  if [ "${CI:-false}" = "true" ] || [ "${FORCE:-false}" = "true" ]; then
    log_info "Running in CI/FORCE mode – auto-confirming: ${prompt}"
    return 0
  fi

  local yn_prompt
  if [ "$default" = "y" ]; then
    yn_prompt="[Y/n]"
  else
    yn_prompt="[y/N]"
  fi

  printf "%b" "$COLOR_BOLD_YELLOW"
  printf "⚠️  %s %s: " "$prompt" "$yn_prompt"
  printf "%b" "$COLOR_RESET"

  local response
  read -r response
  response="${response:-$default}"

  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# Validate Terraform version meets minimum requirement
validate_terraform_version() {
  local min_version="${1:-1.0.0}"
  if ! command -v terraform &>/dev/null; then
    log_error "Terraform is not installed."
    return 1
  fi

  local current_version
  current_version="$(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || terraform version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

  if [ -z "$current_version" ]; then
    log_warn "Could not determine Terraform version."
    return 0
  fi

  # Simple version comparison (major.minor.patch)
  local IFS='.'
  read -ra current <<< "$current_version"
  read -ra minimum <<< "$min_version"

  for i in 0 1 2; do
    local cur="${current[$i]:-0}"
    local min="${minimum[$i]:-0}"
    if [ "$cur" -gt "$min" ]; then
      return 0
    elif [ "$cur" -lt "$min" ]; then
      log_error "Terraform ${current_version} is below minimum required version ${min_version}"
      return 1
    fi
  done
  return 0
}
