#!/usr/bin/env bash
# Terminal color helpers for deployment scripts

# Detect if terminal supports colors
if [ -t 1 ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  COLORS_SUPPORTED=true
else
  COLORS_SUPPORTED=false
fi

if [ "$COLORS_SUPPORTED" = true ]; then
  # Reset
  COLOR_RESET="\033[0m"

  # Regular colors
  COLOR_RED="\033[0;31m"
  COLOR_GREEN="\033[0;32m"
  COLOR_YELLOW="\033[0;33m"
  COLOR_BLUE="\033[0;34m"
  COLOR_MAGENTA="\033[0;35m"
  COLOR_CYAN="\033[0;36m"
  COLOR_WHITE="\033[0;37m"

  # Bold colors
  COLOR_BOLD_RED="\033[1;31m"
  COLOR_BOLD_GREEN="\033[1;32m"
  COLOR_BOLD_YELLOW="\033[1;33m"
  COLOR_BOLD_BLUE="\033[1;34m"
  COLOR_BOLD_MAGENTA="\033[1;35m"
  COLOR_BOLD_CYAN="\033[1;36m"
  COLOR_BOLD_WHITE="\033[1;37m"

  # Background colors
  BG_RED="\033[41m"
  BG_GREEN="\033[42m"
  BG_YELLOW="\033[43m"
  BG_BLUE="\033[44m"
else
  COLOR_RESET=""
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_MAGENTA=""
  COLOR_CYAN=""
  COLOR_WHITE=""
  COLOR_BOLD_RED=""
  COLOR_BOLD_GREEN=""
  COLOR_BOLD_YELLOW=""
  COLOR_BOLD_BLUE=""
  COLOR_BOLD_MAGENTA=""
  COLOR_BOLD_CYAN=""
  COLOR_BOLD_WHITE=""
  BG_RED=""
  BG_GREEN=""
  BG_YELLOW=""
  BG_BLUE=""
fi

# Convenience print functions
print_color() {
  local color="$1"
  shift
  printf "%b%s%b\n" "$color" "$*" "$COLOR_RESET"
}

print_red()    { print_color "$COLOR_RED"    "$@"; }
print_green()  { print_color "$COLOR_GREEN"  "$@"; }
print_yellow() { print_color "$COLOR_YELLOW" "$@"; }
print_blue()   { print_color "$COLOR_BLUE"   "$@"; }
print_cyan()   { print_color "$COLOR_CYAN"   "$@"; }
print_magenta(){ print_color "$COLOR_MAGENTA" "$@"; }

print_bold_red()    { print_color "$COLOR_BOLD_RED"    "$@"; }
print_bold_green()  { print_color "$COLOR_BOLD_GREEN"  "$@"; }
print_bold_yellow() { print_color "$COLOR_BOLD_YELLOW" "$@"; }
print_bold_blue()   { print_color "$COLOR_BOLD_BLUE"   "$@"; }
print_bold_cyan()   { print_color "$COLOR_BOLD_CYAN"   "$@"; }
