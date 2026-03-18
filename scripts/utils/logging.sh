#!/usr/bin/env bash
# Structured logging functions for deployment scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=colors.sh
source "${SCRIPT_DIR}/colors.sh"

# Log file setup
LOG_DIR="${LOG_DIR:-$(git -C "$(dirname "$SCRIPT_DIR")" rev-parse --show-toplevel 2>/dev/null)/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/deployment-$(date +%Y%m%d).log}"

# Ensure log directory exists
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Log levels
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

CURRENT_LOG_LEVEL="${CURRENT_LOG_LEVEL:-$LOG_LEVEL_INFO}"

# Internal: write a log entry
_log_write() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local log_entry="[${timestamp}] [${level}] ${message}"

  # Write to log file
  echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true

  # Write to stdout with color
  case "$level" in
    DEBUG)
      [ "$CURRENT_LOG_LEVEL" -le "$LOG_LEVEL_DEBUG" ] && print_cyan   "[DEBUG] ${message}" ;;
    INFO)
      [ "$CURRENT_LOG_LEVEL" -le "$LOG_LEVEL_INFO"  ] && print_blue   "[INFO]  ${message}" ;;
    SUCCESS)
      [ "$CURRENT_LOG_LEVEL" -le "$LOG_LEVEL_INFO"  ] && print_green  "[OK]    ${message}" ;;
    WARN)
      [ "$CURRENT_LOG_LEVEL" -le "$LOG_LEVEL_WARN"  ] && print_yellow "[WARN]  ${message}" ;;
    ERROR)
      [ "$CURRENT_LOG_LEVEL" -le "$LOG_LEVEL_ERROR" ] && print_red    "[ERROR] ${message}" >&2 ;;
  esac
}

log_debug()   { _log_write "DEBUG"   "$*"; }
log_info()    { _log_write "INFO"    "$*"; }
log_success() { _log_write "SUCCESS" "$*"; }
log_warn()    { _log_write "WARN"    "$*"; }
log_error()   { _log_write "ERROR"   "$*"; }

# Section header
log_section() {
  local title="$1"
  local separator="============================================================"
  _log_write "INFO" "$separator"
  _log_write "INFO" "  ${title}"
  _log_write "INFO" "$separator"
}

# Step indicator
log_step() {
  local step="$1"
  _log_write "INFO" "  --> ${step}"
}

# Banner (startup message)
log_banner() {
  local script_name="$1"
  local environment="${2:-}"
  printf "%b" "$COLOR_BOLD_BLUE"
  echo "╔══════════════════════════════════════════════════════════╗"
  printf "║  %-58s║\n" "${script_name}"
  [ -n "$environment" ] && printf "║  Environment: %-45s║\n" "${environment}"
  printf "║  Started: %-49s║\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "╚══════════════════════════════════════════════════════════╝"
  printf "%b" "$COLOR_RESET"
}

# Duration helper
log_duration() {
  local start_time="$1"
  local end_time
  end_time="$(date +%s)"
  local duration=$(( end_time - start_time ))
  local minutes=$(( duration / 60 ))
  local seconds=$(( duration % 60 ))
  log_info "Total duration: ${minutes}m ${seconds}s"
}
