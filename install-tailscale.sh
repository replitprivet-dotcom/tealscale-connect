#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[tealscale-connect] %s\n' "$*"
}

die() {
  printf '[tealscale-connect] ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  die "Run this installer as root."
fi

: "${TAILSCALE_AUTH_KEY:?Set TAILSCALE_AUTH_KEY to a Tailscale auth key before running.}"
: "${TERMUX_PUBLIC_KEY:?Set TERMUX_PUBLIC_KEY to the Termux public SSH key before running.}"

SSH_USER="${SSH_USER:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-vps-$(hostname -s)}"

if [[ "${TERMUX_PUBLIC_KEY}" != ssh-ed25519\ * && "${TERMUX_PUBLIC_KEY}" != ssh-rsa\ * && "${TERMUX_PUBLIC_KEY}" != ecdsa-sha2-*\ * ]]; then
  die "TERMUX_PUBLIC_KEY does not look like an SSH public key."
fi

if ! command -v apt-get >/dev/null 2>&1; then
  die "This installer currently supports Debian/Ubuntu systems with apt-get."
fi

export DEBIAN_FRONTEND=noninteractive
log "Installing required packages."
apt-get update -y
apt-get install -y ca-certificates curl openssh-server

log "Enabling the SSH service."
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
else
  service ssh start 2>/dev/null || service sshd start 2>/dev/null || true
fi

if ! command -v tailscale >/dev/null 2>&1; then
  log "Installing Tailscale."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

command -v tailscale >/dev/null 2>&1 || die "Tailscale installation did not provide the tailscale command."

log "Joining the Tailscale network as ${TAILSCALE_HOSTNAME}."
tailscale up --auth-key="${TAILSCALE_AUTH_KEY}" --hostname="${TAILSCALE_HOSTNAME}" --ssh=false

add_authorized_key() {
  local account="$1"
  local home_dir uid gid auth_file

  home_dir="$(getent passwd "${account}" | cut -d: -f6)"
  [[ -n "${home_dir}" && -d "${home_dir}" ]] || die "Could not resolve home directory for ${account}."
  uid="$(id -u "${account}")"
  gid="$(id -g "${account}")"
  auth_file="${home_dir}/.ssh/authorized_keys"

  install -d -m 700 -o "${uid}" -g "${gid}" "${home_dir}/.ssh"
  touch "${auth_file}"
  chown "${uid}:${gid}" "${auth_file}"
  chmod 600 "${auth_file}"

  if ! grep -Fqx -- "${TERMUX_PUBLIC_KEY}" "${auth_file}"; then
    printf '%s\n' "${TERMUX_PUBLIC_KEY}" >> "${auth_file}"
  fi

  chown "${uid}:${gid}" "${auth_file}"
  chmod 600 "${auth_file}"
  log "Authorized the supplied public key for ${account}."
}

add_authorized_key root
if [[ -n "${SSH_USER}" ]]; then
  id "${SSH_USER}" >/dev/null 2>&1 || die "SSH_USER does not exist: ${SSH_USER}"
  [[ "${SSH_USER}" != root ]] && add_authorized_key "${SSH_USER}"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi

TAILSCALE_IP="$(tailscale ip -4 | head -n 1 || true)"
[[ -n "${TAILSCALE_IP}" ]] || die "Tailscale did not return an IPv4 address."

printf '\nSetup complete.\n'
printf 'Tailscale hostname: %s\n' "${TAILSCALE_HOSTNAME}"
printf 'Tailscale IPv4: %s\n' "${TAILSCALE_IP}"
printf '\nConnect from Termux:\n'
printf '  ssh root@%s\n' "${TAILSCALE_IP}"
printf '\nIf you want to select the key explicitly:\n'
printf '  ssh -i ~/.ssh/id_ed25519 root@%s\n' "${TAILSCALE_IP}"
