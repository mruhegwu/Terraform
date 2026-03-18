#!/usr/bin/env bash
# validate.sh - Validation and compliance checks
# Usage: scripts/validate.sh [environment]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=utils/logging.sh
source "${SCRIPT_DIR}/utils/logging.sh"
# shellcheck source=utils/validation.sh
source "${SCRIPT_DIR}/utils/validation.sh"

ENVIRONMENT="${1:-}"
WORKING_DIR="${WORKING_DIR:-$REPO_ROOT}"
FAILED=0
START_TIME="$(date +%s)"

log_banner "Terraform Validation" "${ENVIRONMENT:-all}"

# ─── Check required tools ──────────────────────────────────────────────────────
log_section "Tool Availability"

for tool in terraform; do
  if validate_command "$tool"; then
    log_success "${tool} is available: $(${tool} version 2>/dev/null | head -1)"
  else
    FAILED=1
  fi
done

# Optional tools
for tool in tflint checkov terraform-docs; do
  if command -v "$tool" &>/dev/null; then
    log_success "${tool} is available"
  else
    log_warn "${tool} is not installed (optional)"
  fi
done

# ─── Terraform format check ───────────────────────────────────────────────────
log_section "Terraform Format Check"
if command -v terraform &>/dev/null; then
  if terraform -chdir="$WORKING_DIR" fmt -check -recursive; then
    log_success "All Terraform files are properly formatted."
  else
    log_warn "Some Terraform files need formatting. Run: terraform fmt -recursive"
  fi
fi

# ─── Terraform validate ───────────────────────────────────────────────────────
log_section "Terraform Validate"
if command -v terraform &>/dev/null; then
  # Init first if needed
  if [ ! -d "${WORKING_DIR}/.terraform" ]; then
    log_step "Initialising Terraform..."
    terraform -chdir="$WORKING_DIR" init -backend=false -reconfigure &>/dev/null || true
  fi

  if terraform -chdir="$WORKING_DIR" validate; then
    log_success "Terraform configuration is valid."
  else
    log_error "Terraform validation failed."
    FAILED=1
  fi
fi

# ─── TFLint ───────────────────────────────────────────────────────────────────
log_section "TFLint"
if command -v tflint &>/dev/null; then
  if tflint --chdir="$WORKING_DIR"; then
    log_success "TFLint checks passed."
  else
    log_error "TFLint found issues."
    FAILED=1
  fi
else
  log_warn "TFLint not installed – skipping."
fi

# ─── Checkov security scan ────────────────────────────────────────────────────
log_section "Checkov Security Scan"
if command -v checkov &>/dev/null; then
  if checkov -d "$WORKING_DIR" --quiet --compact; then
    log_success "Checkov security scan passed."
  else
    log_warn "Checkov found security issues – review output above."
    # Not failing the entire validation for security warnings
  fi
else
  log_warn "Checkov not installed – skipping security scan."
fi

# ─── Environment-specific checks ─────────────────────────────────────────────
if [ -n "$ENVIRONMENT" ]; then
  log_section "Environment Validation – ${ENVIRONMENT}"
  validate_environment "$ENVIRONMENT" || FAILED=1

  TFVARS_FILE="${REPO_ROOT}/environments/${ENVIRONMENT}.tfvars"
  if [ -f "$TFVARS_FILE" ]; then
    log_success "tfvars file found: ${TFVARS_FILE}"
  else
    log_warn "No tfvars file found at: ${TFVARS_FILE}"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
log_section "Validation Summary"
if [ $FAILED -eq 0 ]; then
  log_success "All validation checks passed!"
else
  log_error "One or more validation checks failed. See above for details."
fi

log_duration "$START_TIME"
exit $FAILED
