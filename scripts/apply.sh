#!/usr/bin/env bash
# apply.sh - Terraform apply wrapper
# Usage: scripts/apply.sh <environment> [--auto-approve] [extra terraform flags]

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
AUTO_APPROVE=false
EXTRA_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --auto-approve) AUTO_APPROVE=true ;;
    *) EXTRA_ARGS+=("$arg") ;;
  esac
done

# ─── Validate inputs ───────────────────────────────────────────────────────────
if [ -z "$ENVIRONMENT" ]; then
  log_error "Usage: $0 <environment> [--auto-approve] [extra terraform flags]"
  log_error "  Environments: dev, staging, prod"
  exit 1
fi

validate_environment "$ENVIRONMENT" || exit 1
ENVIRONMENT="$(normalize_environment "$ENVIRONMENT")"

# ─── Safety check for production ───────────────────────────────────────────────
if [ "$ENVIRONMENT" = "prod" ] && [ "$AUTO_APPROVE" = "false" ]; then
  log_warn "You are about to apply changes to PRODUCTION!"
  confirm_action "Apply Terraform changes to PRODUCTION?" "n" || {
    log_info "Apply cancelled by user."
    exit 0
  }
fi

# ─── Setup ─────────────────────────────────────────────────────────────────────
START_TIME="$(date +%s)"
log_banner "Terraform Apply" "$ENVIRONMENT"

TFVARS_FILE="${REPO_ROOT}/environments/${ENVIRONMENT}.tfvars"
PLAN_FILE="${REPO_ROOT}/plans/${ENVIRONMENT}.tfplan"
WORKING_DIR="${WORKING_DIR:-$REPO_ROOT}"

validate_required_commands terraform

# ─── Backup state before apply ─────────────────────────────────────────────────
if [ -f "${WORKING_DIR}/terraform.tfstate" ]; then
  log_step "Backing up current state before apply..."
  "${SCRIPT_DIR}/backup-state.sh" "$ENVIRONMENT" || log_warn "State backup failed – proceeding anyway."
fi

# ─── Determine apply source (plan file or var file) ────────────────────────────
APPLY_ARGS=()
if [ -f "$PLAN_FILE" ]; then
  log_info "Applying saved plan: ${PLAN_FILE}"
  APPLY_ARGS=("$PLAN_FILE")
else
  log_warn "No saved plan found at ${PLAN_FILE}. Applying directly with var file."
  if [ -f "$TFVARS_FILE" ]; then
    APPLY_ARGS=("-var-file=${TFVARS_FILE}")
  fi
fi

# ─── Terraform init (if needed) ────────────────────────────────────────────────
if [ ! -d "${WORKING_DIR}/.terraform" ]; then
  log_step "Running terraform init..."
  terraform -chdir="$WORKING_DIR" init -reconfigure
fi

# ─── Terraform apply ───────────────────────────────────────────────────────────
log_section "Terraform Apply – ${ENVIRONMENT}"

AUTO_APPROVE_FLAG=()
if [ "$AUTO_APPROVE" = "true" ]; then
  AUTO_APPROVE_FLAG=("-auto-approve")
fi

terraform -chdir="$WORKING_DIR" apply \
  "${AUTO_APPROVE_FLAG[@]}" \
  "${APPLY_ARGS[@]}" \
  "${EXTRA_ARGS[@]}"

APPLY_EXIT=$?

if [ $APPLY_EXIT -eq 0 ]; then
  log_success "Terraform apply completed successfully for environment: ${ENVIRONMENT}"
else
  log_error "Terraform apply failed (exit code: ${APPLY_EXIT})"
  exit $APPLY_EXIT
fi

log_duration "$START_TIME"
