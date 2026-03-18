#!/usr/bin/env bash
# restore-state.sh - Terraform state file recovery
# Usage: scripts/restore-state.sh <environment> [backup-file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=utils/logging.sh
source "${SCRIPT_DIR}/utils/logging.sh"
# shellcheck source=utils/validation.sh
source "${SCRIPT_DIR}/utils/validation.sh"

ENVIRONMENT="${1:-}"
BACKUP_FILE="${2:-}"

if [ -z "$ENVIRONMENT" ]; then
  log_error "Usage: $0 <environment> [backup-file]"
  log_error ""
  log_error "  If backup-file is not specified, the most recent backup is used."
  exit 1
fi

validate_environment "$ENVIRONMENT" || exit 1
ENVIRONMENT="$(normalize_environment "$ENVIRONMENT")"

log_banner "State Restore" "$ENVIRONMENT"

WORKING_DIR="${WORKING_DIR:-$REPO_ROOT}"
BACKUP_DIR="${REPO_ROOT}/backups/state"

# ─── Find backup file ──────────────────────────────────────────────────────────
if [ -z "$BACKUP_FILE" ]; then
  log_info "No backup file specified. Looking for most recent backup..."
  BACKUP_FILE="$(find "$BACKUP_DIR" -name "${ENVIRONMENT}-*.tfstate" 2>/dev/null | sort | tail -1 || true)"
  if [ -z "$BACKUP_FILE" ]; then
    log_error "No backup files found in ${BACKUP_DIR} for environment '${ENVIRONMENT}'."
    log_info "Available backups:"
    find "$BACKUP_DIR" -name "*.tfstate" 2>/dev/null | sort || echo "  (none)"
    exit 1
  fi
  log_info "Using most recent backup: ${BACKUP_FILE}"
fi

validate_file "$BACKUP_FILE" || exit 1

# ─── Confirm restore ──────────────────────────────────────────────────────────
log_warn "This will OVERWRITE the current Terraform state for '${ENVIRONMENT}'!"
log_warn "Backup file: ${BACKUP_FILE}"
confirm_action "Restore state from backup?" "n" || {
  log_info "Restore cancelled."
  exit 0
}

# ─── Safety backup of current state ──────────────────────────────────────────
log_step "Creating safety backup of current state..."
"${SCRIPT_DIR}/backup-state.sh" "$ENVIRONMENT" || log_warn "Could not create safety backup."

# ─── Restore state ────────────────────────────────────────────────────────────
if command -v terraform &>/dev/null && [ -d "${WORKING_DIR}/.terraform" ]; then
  log_step "Pushing backup state to remote backend via terraform state push..."
  terraform -chdir="$WORKING_DIR" state push -force "$BACKUP_FILE"
  log_success "State successfully pushed to remote backend."
else
  log_step "Copying backup state to local state file..."
  cp "$BACKUP_FILE" "${WORKING_DIR}/terraform.tfstate"
  log_success "State restored to: ${WORKING_DIR}/terraform.tfstate"
fi

log_success "State restore complete for environment: ${ENVIRONMENT}"
