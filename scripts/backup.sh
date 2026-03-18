#!/usr/bin/env bash
# backup.sh - State backup before deployment
# Usage: scripts/backup.sh <environment>
# This is an alias for backup-state.sh for convenience.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/backup-state.sh" "$@"
