#!/usr/bin/env bash
# deploy.sh - Main deployment orchestrator
# Usage: scripts/deploy.sh <environment> [--skip-plan] [--skip-backup] [--auto-approve]

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
SKIP_PLAN=false
SKIP_BACKUP=false
AUTO_APPROVE=false
DRY_RUN=false
EXTRA_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --skip-plan)   SKIP_PLAN=true ;;
    --skip-backup) SKIP_BACKUP=true ;;
    --auto-approve) AUTO_APPROVE=true ;;
    --dry-run)     DRY_RUN=true ;;
    *) EXTRA_ARGS+=("$arg") ;;
  esac
done

# ─── Validate inputs ───────────────────────────────────────────────────────────
if [ -z "$ENVIRONMENT" ]; then
  log_error "Usage: $0 <environment> [options]"
  log_error ""
  log_error "  Environments: dev, staging, prod"
  log_error ""
  log_error "  Options:"
  log_error "    --skip-plan    Skip the plan step (use saved plan)"
  log_error "    --skip-backup  Skip state backup"
  log_error "    --auto-approve Skip interactive confirmation"
  log_error "    --dry-run      Show what would happen without making changes"
  exit 1
fi

validate_environment "$ENVIRONMENT" || exit 1
ENVIRONMENT="$(normalize_environment "$ENVIRONMENT")"

START_TIME="$(date +%s)"
log_banner "Terraform Deployment Orchestrator" "$ENVIRONMENT"

if [ "$DRY_RUN" = "true" ]; then
  log_warn "DRY RUN MODE – no infrastructure changes will be made."
fi

# ─── Step 1: Pre-deployment checks ────────────────────────────────────────────
log_section "Step 1/5: Pre-Deployment Checks"
if [ "$DRY_RUN" = "false" ]; then
  "${SCRIPT_DIR}/pre-deployment-check.sh" "$ENVIRONMENT" || {
    log_error "Pre-deployment checks failed. Aborting deployment."
    exit 1
  }
else
  log_info "[DRY RUN] Would run pre-deployment checks."
fi

# ─── Step 2: Validate configuration ───────────────────────────────────────────
log_section "Step 2/5: Validate Configuration"
if [ "$DRY_RUN" = "false" ]; then
  "${SCRIPT_DIR}/validate.sh" "$ENVIRONMENT" || {
    log_error "Validation failed. Aborting deployment."
    exit 1
  }
else
  log_info "[DRY RUN] Would validate Terraform configuration."
fi

# ─── Step 3: Backup state ─────────────────────────────────────────────────────
log_section "Step 3/5: State Backup"
if [ "$SKIP_BACKUP" = "true" ]; then
  log_warn "State backup skipped (--skip-backup flag set)."
elif [ "$DRY_RUN" = "false" ]; then
  "${SCRIPT_DIR}/backup-state.sh" "$ENVIRONMENT" || log_warn "Backup failed – proceeding anyway."
else
  log_info "[DRY RUN] Would backup state."
fi

# ─── Step 4: Plan ─────────────────────────────────────────────────────────────
log_section "Step 4/5: Terraform Plan"
if [ "$SKIP_PLAN" = "true" ]; then
  log_info "Plan step skipped (--skip-plan flag set). Using saved plan if available."
elif [ "$DRY_RUN" = "false" ]; then
  "${SCRIPT_DIR}/plan.sh" "$ENVIRONMENT" "${EXTRA_ARGS[@]}" || {
    log_error "Terraform plan failed. Aborting deployment."
    exit 1
  }
else
  log_info "[DRY RUN] Would run: plan.sh ${ENVIRONMENT}"
fi

# ─── Step 5: Apply ────────────────────────────────────────────────────────────
log_section "Step 5/5: Terraform Apply"
if [ "$DRY_RUN" = "false" ]; then
  APPLY_FLAGS=()
  [ "$AUTO_APPROVE" = "true" ] && APPLY_FLAGS+=("--auto-approve")

  "${SCRIPT_DIR}/apply.sh" "$ENVIRONMENT" "${APPLY_FLAGS[@]}" "${EXTRA_ARGS[@]}" || {
    log_error "Terraform apply failed."
    exit 1
  }
else
  log_info "[DRY RUN] Would run: apply.sh ${ENVIRONMENT}"
fi

# ─── Completion ───────────────────────────────────────────────────────────────
log_section "Deployment Complete"
if [ "$DRY_RUN" = "true" ]; then
  log_success "Dry run completed – no changes were made."
else
  log_success "Deployment to '${ENVIRONMENT}' completed successfully!"
fi

log_duration "$START_TIME"
