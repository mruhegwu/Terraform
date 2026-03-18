#!/usr/bin/env bash
# backup-state.sh - Terraform state file backup
# Usage: scripts/backup-state.sh <environment>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=utils/logging.sh
source "${SCRIPT_DIR}/utils/logging.sh"
# shellcheck source=utils/validation.sh
source "${SCRIPT_DIR}/utils/validation.sh"

ENVIRONMENT="${1:-}"

if [ -z "$ENVIRONMENT" ]; then
  log_error "Usage: $0 <environment>"
  exit 1
fi

validate_environment "$ENVIRONMENT" || exit 1
ENVIRONMENT="$(normalize_environment "$ENVIRONMENT")"

START_TIME="$(date +%s)"
log_banner "State Backup" "$ENVIRONMENT"

WORKING_DIR="${WORKING_DIR:-$REPO_ROOT}"
BACKUP_DIR="${REPO_ROOT}/backups/state"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/${ENVIRONMENT}-${TIMESTAMP}.tfstate"

mkdir -p "$BACKUP_DIR"

# ─── Check if we have a local state file ──────────────────────────────────────
LOCAL_STATE="${WORKING_DIR}/terraform.tfstate"

if [ -f "$LOCAL_STATE" ]; then
  log_step "Backing up local state file..."
  cp "$LOCAL_STATE" "$BACKUP_FILE"
  log_success "Local state backed up to: ${BACKUP_FILE}"
else
  log_info "No local state file found. Attempting to pull from remote backend..."
  # Attempt terraform state pull if terraform is available
  if command -v terraform &>/dev/null && [ -d "${WORKING_DIR}/.terraform" ]; then
    log_step "Pulling state from remote backend..."
    terraform -chdir="$WORKING_DIR" state pull > "$BACKUP_FILE" 2>/dev/null && {
      # Check if we got a valid state (not empty)
      if [ -s "$BACKUP_FILE" ] && grep -q '"serial"' "$BACKUP_FILE" 2>/dev/null; then
        log_success "Remote state backed up to: ${BACKUP_FILE}"
      else
        rm -f "$BACKUP_FILE"
        log_warn "State pull returned empty content – no backup created."
      fi
    } || {
      rm -f "$BACKUP_FILE" 2>/dev/null || true
      log_warn "Could not pull remote state. Backend may not be configured yet."
    }
  else
    log_warn "Terraform not initialised – skipping remote state pull."
  fi
fi

# ─── Rotate old backups (keep last 30) ────────────────────────────────────────
BACKUP_COUNT="$(find "$BACKUP_DIR" -name "${ENVIRONMENT}-*.tfstate" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$BACKUP_COUNT" -gt 30 ]; then
  log_info "Rotating old backups (keeping last 30)..."
  find "$BACKUP_DIR" -name "${ENVIRONMENT}-*.tfstate" \
    | sort | head -n "$(( BACKUP_COUNT - 30 ))" \
    | xargs rm -f
  log_info "Old backups removed."
fi

log_success "Backup complete for environment: ${ENVIRONMENT}"
log_info "Backup location: ${BACKUP_DIR}"
log_duration "$START_TIME"
