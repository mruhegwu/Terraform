#!/usr/bin/env bash
# destroy.sh - Terraform infrastructure teardown
# Usage: scripts/destroy.sh <environment> [--force] [extra terraform flags]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=utils/logging.sh
source "${SCRIPT_DIR}/utils/logging.sh"
# shellcheck source=utils/validation.sh
source "${SCRIPT_DIR}/utils/validation.sh"

ENVIRONMENT="${1:-}"
shift || true

# ─── Parse flags ───────────────────────────────────────────────────────────────
FORCE=false
EXTRA_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *) EXTRA_ARGS+=("$arg") ;;
  esac
done

# ─── Validate inputs ───────────────────────────────────────────────────────────
if [ -z "$ENVIRONMENT" ]; then
  log_error "Usage: $0 <environment> [--force] [extra terraform flags]"
  log_error "  Environments: dev, staging, prod"
  exit 1
fi

validate_environment "$ENVIRONMENT" || exit 1
ENVIRONMENT="$(normalize_environment "$ENVIRONMENT")"

# ─── Double-confirmation for production ────────────────────────────────────────
if [ "$ENVIRONMENT" = "prod" ]; then
  log_error "╔══════════════════════════════════════════════════════════╗"
  log_error "║         ⚠️  DESTRUCTIVE OPERATION – PRODUCTION ⚠️           ║"
  log_error "║  This will PERMANENTLY DESTROY all production resources! ║"
  log_error "╚══════════════════════════════════════════════════════════╝"

  if [ "$FORCE" = "false" ]; then
    confirm_action "Type 'destroy production' to confirm" "n" || {
      log_info "Destroy cancelled."
      exit 0
    }
    printf "Confirm by typing exactly 'destroy production': "
    read -r confirmation
    if [ "$confirmation" != "destroy production" ]; then
      log_info "Confirmation text did not match. Aborting."
      exit 1
    fi
  fi
elif [ "$ENVIRONMENT" = "staging" ] && [ "$FORCE" = "false" ]; then
  confirm_action "Destroy ALL staging infrastructure?" "n" || {
    log_info "Destroy cancelled."
    exit 0
  }
fi

# ─── Setup ─────────────────────────────────────────────────────────────────────
START_TIME="$(date +%s)"
log_banner "Terraform Destroy" "$ENVIRONMENT"

TFVARS_FILE="${REPO_ROOT}/environments/${ENVIRONMENT}.tfvars"
WORKING_DIR="${WORKING_DIR:-$REPO_ROOT}"

validate_required_commands terraform

# ─── Backup state before destroy ───────────────────────────────────────────────
log_step "Creating state backup before destroy..."
"${SCRIPT_DIR}/backup-state.sh" "$ENVIRONMENT" || log_warn "State backup failed – proceeding anyway."

# ─── Terraform init (if needed) ────────────────────────────────────────────────
if [ ! -d "${WORKING_DIR}/.terraform" ]; then
  log_step "Running terraform init..."
  terraform -chdir="$WORKING_DIR" init -reconfigure
fi

# ─── Terraform destroy ─────────────────────────────────────────────────────────
log_section "Terraform Destroy – ${ENVIRONMENT}"

VAR_FILE_ARGS=()
if [ -f "$TFVARS_FILE" ]; then
  VAR_FILE_ARGS=("-var-file=${TFVARS_FILE}")
fi

terraform -chdir="$WORKING_DIR" destroy \
  -auto-approve \
  "${VAR_FILE_ARGS[@]}" \
  "${EXTRA_ARGS[@]}"

DESTROY_EXIT=$?

if [ $DESTROY_EXIT -eq 0 ]; then
  log_success "Infrastructure destroyed successfully for environment: ${ENVIRONMENT}"
else
  log_error "Terraform destroy failed (exit code: ${DESTROY_EXIT})"
  exit $DESTROY_EXIT
fi

log_duration "$START_TIME"
