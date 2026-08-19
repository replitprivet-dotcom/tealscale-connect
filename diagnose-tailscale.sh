#!/usr/bin/env bash
set -u

SOCKET="${TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}"
LOG_FILE="${TAILSCALE_LOG:-/var/log/tailscaled.log}"

printf '%s\n' '=== tealscale-connect diagnostics ==='
printf 'Host: '; hostname 2>/dev/null || true
printf 'Date: '; date 2>/dev/null || true
printf '\n--- Processes ---\n'
pgrep -af tailscaled 2>/dev/null || echo 'tailscaled process not found'
printf '\n--- Socket ---\n'
if [[ -S "${SOCKET}" ]]; then
  ls -l "${SOCKET}"
else
  echo "Missing socket: ${SOCKET}"
fi
printf '\n--- Service ---\n'
if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active tailscaled 2>/dev/null || true
  systemctl is-enabled tailscaled 2>/dev/null || true
fi
printf '\n--- Tailscale status ---\n'
if command -v tailscale >/dev/null 2>&1; then
  tailscale --socket="${SOCKET}" status 2>&1 || true
  printf '\nTailscale IPv4: '
  tailscale --socket="${SOCKET}" ip -4 2>&1 || true
else
  echo 'tailscale command not found'
fi
printf '\n--- SSH listener ---\n'
if command -v ss >/dev/null 2>&1; then
  ss -lntp 2>/dev/null | grep -E '(:22[[:space:]]|:ssh[[:space:]])' || echo 'SSH listener not found'
else
  echo 'ss command not found'
fi
printf '\n--- Recent daemon log ---\n'
tail -40 "${LOG_FILE}" 2>/dev/null || echo "No daemon log at ${LOG_FILE}"
printf '\n=== End diagnostics ===\n'
