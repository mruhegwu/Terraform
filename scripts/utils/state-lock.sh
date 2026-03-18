#!/usr/bin/env bash
# Terraform state lock management utilities

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=logging.sh
source "${SCRIPT_DIR}/logging.sh"

# Default lock timeout in seconds (5 minutes)
LOCK_TIMEOUT="${LOCK_TIMEOUT:-300}"

# Check if the Terraform state is currently locked
check_state_lock() {
  local working_dir="${1:-.}"
  log_info "Checking Terraform state lock in: ${working_dir}"

  if ! command -v terraform &>/dev/null; then
    log_warn "Terraform not found – skipping lock check."
    return 0
  fi

  local lock_info
  lock_info="$(terraform -chdir="$working_dir" force-unlock -help 2>&1 || true)"

  # Attempt a plan with no changes to detect lock
  local output
  if output="$(terraform -chdir="$working_dir" plan -detailed-exitcode -lock=false -no-color 2>&1)"; then
    log_success "State is accessible (no lock detected)."
    return 0
  fi

  if echo "$output" | grep -q "state blob is already locked\|Error locking state\|lock"; then
    log_warn "State appears to be locked."
    echo "$output" | grep -i "lock" | head -5
    return 1
  fi

  return 0
}

# Force-unlock the Terraform state (use with caution)
force_unlock_state() {
  local working_dir="${1:-.}"
  local lock_id="$2"
  local working_dir="${1:-.}"

  if [ -z "$lock_id" ]; then
    log_error "Lock ID is required for force-unlock."
    log_info "Find the lock ID in the error message from the failed operation."
    return 1
  fi

  log_warn "Force-unlocking state with lock ID: ${lock_id}"
  log_warn "This is a potentially dangerous operation!"

  terraform -chdir="$working_dir" force-unlock -force "$lock_id"
  local exit_code=$?

  if [ $exit_code -eq 0 ]; then
    log_success "State lock released successfully."
  else
    log_error "Failed to release state lock (exit code: ${exit_code})."
  fi

  return $exit_code
}

# Wait for state lock to be released (poll with timeout)
wait_for_lock_release() {
  local working_dir="${1:-.}"
  local timeout="${2:-$LOCK_TIMEOUT}"
  local poll_interval=15
  local elapsed=0

  log_info "Waiting up to ${timeout}s for state lock to be released..."

  while [ "$elapsed" -lt "$timeout" ]; do
    if ! check_state_lock "$working_dir" 2>/dev/null; then
      log_info "State still locked. Retrying in ${poll_interval}s... (${elapsed}/${timeout}s elapsed)"
      sleep "$poll_interval"
      elapsed=$(( elapsed + poll_interval ))
    else
      log_success "State lock has been released."
      return 0
    fi
  done

  log_error "Timed out after ${timeout}s waiting for state lock release."
  return 1
}

# Get information about the current state lock
get_lock_info() {
  local working_dir="${1:-.}"
  local state_file="${working_dir}/terraform.tfstate"

  if [ -f "$state_file" ]; then
    log_info "Checking local state file for lock info: ${state_file}"
    if command -v jq &>/dev/null; then
      jq -r '.serial, .lineage' "$state_file" 2>/dev/null || true
    fi
  fi

  # For remote backends, lock info is in the backend
  log_info "For remote backend locks, check your backend provider's console."
  log_info "  AWS S3/DynamoDB: Check DynamoDB table for lock entries."
  log_info "  Terraform Cloud: Check workspace run queue."
  log_info "  GCS: Check GCS object metadata."
}
