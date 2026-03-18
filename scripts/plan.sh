#!/usr/bin/env bash
# plan.sh - Terraform plan wrapper
# Usage: scripts/plan.sh <environment> [extra terraform flags]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=utils/logging.sh
source "${SCRIPT_DIR}/utils/logging.sh"
# shellcheck source=utils/validation.sh
source "${SCRIPT_DIR}/utils/validation.sh"

ENVIRONMENT="${1:-}"
shift || true
EXTRA_ARGS=("$@")

# ─── Validate inputs ───────────────────────────────────────────────────────────
if [ -z "$ENVIRONMENT" ]; then
  log_error "Usage: $0 <environment> [extra terraform flags]"
  log_error "  Environments: dev, staging, prod"
  exit 1
fi

validate_environment "$ENVIRONMENT" || exit 1
ENVIRONMENT="$(normalize_environment "$ENVIRONMENT")"

# ─── Setup ─────────────────────────────────────────────────────────────────────
START_TIME="$(date +%s)"
log_banner "Terraform Plan" "$ENVIRONMENT"

TFVARS_FILE="${REPO_ROOT}/environments/${ENVIRONMENT}.tfvars"
PLAN_FILE="${REPO_ROOT}/plans/${ENVIRONMENT}.tfplan"
WORKING_DIR="${WORKING_DIR:-$REPO_ROOT}"

validate_required_commands terraform
mkdir -p "${REPO_ROOT}/plans"

# ─── Determine var file ────────────────────────────────────────────────────────
VAR_FILE_ARGS=()
if [ -f "$TFVARS_FILE" ]; then
  log_info "Using tfvars file: ${TFVARS_FILE}"
  VAR_FILE_ARGS=("-var-file=${TFVARS_FILE}")
else
  log_warn "No tfvars file found at ${TFVARS_FILE}. Proceeding without it."
fi

# ─── Terraform init (if .terraform dir is absent) ──────────────────────────────
if [ ! -d "${WORKING_DIR}/.terraform" ]; then
  log_step "Running terraform init..."
  terraform -chdir="$WORKING_DIR" init -reconfigure
fi

# ─── Terraform plan ────────────────────────────────────────────────────────────
log_section "Terraform Plan – ${ENVIRONMENT}"
log_step "Generating plan..."

terraform -chdir="$WORKING_DIR" plan \
  "${VAR_FILE_ARGS[@]}" \
  -out="${PLAN_FILE}" \
  "${EXTRA_ARGS[@]}"

PLAN_EXIT=$?

if [ $PLAN_EXIT -eq 0 ]; then
  log_success "Plan saved to: ${PLAN_FILE}"
elif [ $PLAN_EXIT -eq 2 ]; then
  # exit code 2 = changes present (only with -detailed-exitcode)
  log_success "Plan completed – changes detected."
else
  log_error "Terraform plan failed (exit code: ${PLAN_EXIT})"
  exit $PLAN_EXIT
fi

log_duration "$START_TIME"
