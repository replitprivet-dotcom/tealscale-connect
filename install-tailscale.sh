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

if ! command -v apt-get >/dev/null 2>&1; then
  die "This installer currently supports Debian/Ubuntu systems with apt-get."
fi

# This is a public SSH key, not a private credential. Override it by setting
# TERMUX_PUBLIC_KEY before running the script if a different phone key is needed.
TERMUX_PUBLIC_KEY="${TERMUX_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ7/CaZDCx4g2Vx62y/FhnQmIwXFckUL4JSVizhP+S2a u0_a275@localhost}"
SSH_USER="${SSH_USER:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-vps-$(hostname -s)}"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

if [[ "${TERMUX_PUBLIC_KEY}" != ssh-ed25519\ * && "${TERMUX_PUBLIC_KEY}" != ssh-rsa\ * && "${TERMUX_PUBLIC_KEY}" != ecdsa-sha2-*\ * ]]; then
  die "TERMUX_PUBLIC_KEY does not look like an SSH public key."
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

start_tailscaled() {
  if pgrep -x tailscaled >/dev/null 2>&1; then
    return 0
  fi

  log "Starting tailscaled."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now tailscaled 2>/dev/null || true
  fi

  if ! pgrep -x tailscaled >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    service tailscaled start 2>/dev/null || true
  fi

  # Some VPS containers have no working systemd PID 1. Start the daemon
  # directly as a fallback in that environment.
  if ! pgrep -x tailscaled >/dev/null 2>&1; then
    install -d -m 755 /var/lib/tailscale /var/run/tailscale
    nohup tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock \
      >/var/log/tailscaled.log 2>&1 &
  fi

  for _ in $(seq 1 30); do
    if pgrep -x tailscaled >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  log "tailscaled did not start. Recent daemon log:"
  tail -20 /var/log/tailscaled.log 2>/dev/null || true
  die "Could not start tailscaled."
}

start_tailscaled

read_tty() {
  local prompt="$1"
  local value
  if [[ ! -r /dev/tty ]]; then
    die "Interactive setup needs a TTY. Set TAILSCALE_AUTH_KEY for non-interactive setup."
  fi
  printf '%s' "${prompt}" >/dev/tty
  IFS= read -r value </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "${value}"
}

read_secret_tty() {
  local prompt="$1"
  local value
  if [[ ! -r /dev/tty ]]; then
    die "Interactive setup needs a TTY. Set TAILSCALE_AUTH_KEY for non-interactive setup."
  fi
  printf '%s' "${prompt}" >/dev/tty
  IFS= read -r -s value </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "${value}"
}

if tailscale ip -4 >/dev/null 2>&1; then
  log "Tailscale is already connected; keeping the existing node login."
  tailscale set --hostname="${TAILSCALE_HOSTNAME}" 2>/dev/null || true
else
  if [[ -z "${TAILSCALE_AUTH_KEY}" ]]; then
    printf '\nTailscale setup options:\n' >/dev/tty
    printf '  1) Paste a Tailscale auth key for automatic setup\n' >/dev/tty
    printf '  2) Use a Tailscale login URL\n\n' >/dev/tty
    choice="$(read_tty 'Choose 1 or 2 [default: 2]: ' )"
    choice="${choice:-2}"

    case "${choice}" in
      1)
        TAILSCALE_AUTH_KEY="$(read_secret_tty 'Paste Tailscale auth key (hidden): ' )"
        [[ -n "${TAILSCALE_AUTH_KEY}" ]] || die "No auth key was provided."
        ;;
      2)
        log "Starting interactive Tailscale login. Open the URL printed below in any browser."
        set +e
        tailscale up --hostname="${TAILSCALE_HOSTNAME}" --ssh=false
        tailscale_rc=$?
        set -e
        if [[ "${tailscale_rc}" -ne 0 ]]; then
          log "Tailscale returned ${tailscale_rc}; waiting in case browser login is still completing."
        fi
        ;;
      *)
        die "Choose 1 or 2."
        ;;
    esac
  fi

  if [[ -n "${TAILSCALE_AUTH_KEY}" ]]; then
    log "Joining Tailscale automatically as ${TAILSCALE_HOSTNAME}."
    tailscale up --auth-key="${TAILSCALE_AUTH_KEY}" --hostname="${TAILSCALE_HOSTNAME}" --ssh=false
  fi
fi

wait_for_tailscale_ip() {
  local ip=""
  local attempt
  for attempt in $(seq 1 60); do
    ip="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [[ -n "${ip}" ]]; then
      printf '%s' "${ip}"
      return 0
    fi
    sleep 5
  done
  return 1
}

TAILSCALE_IP="$(wait_for_tailscale_ip || true)"
[[ -n "${TAILSCALE_IP}" ]] || die "Tailscale is not connected yet. Complete the login URL and rerun the same command."

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

printf '\nSetup complete.\n'
printf 'Tailscale hostname: %s\n' "${TAILSCALE_HOSTNAME}"
printf 'Tailscale IPv4: %s\n' "${TAILSCALE_IP}"
printf '\nConnect from Termux:\n'
printf '  ssh root@%s\n' "${TAILSCALE_IP}"
printf '\nIf you want to select the key explicitly:\n'
printf '  ssh -i ~/.ssh/id_ed25519 root@%s\n' "${TAILSCALE_IP}"
