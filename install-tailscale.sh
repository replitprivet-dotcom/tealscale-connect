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
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}"
TAILSCALE_STATE="${TAILSCALE_STATE:-/var/lib/tailscale/tailscaled.state}"
TAILSCALE_LOG="${TAILSCALE_LOG:-/var/log/tailscaled.log}"
TAILSCALE_SSH_PORT="${TAILSCALE_SSH_PORT:-2222}"
TAILSCALE_USERSPACE=0
if [[ ! -e /dev/net/tun ]]; then
  TAILSCALE_USERSPACE=1
  log "No /dev/net/tun detected; enabling container userspace networking."
fi


if [[ "${TERMUX_PUBLIC_KEY}" != ssh-ed25519\ * && "${TERMUX_PUBLIC_KEY}" != ssh-rsa\ * && "${TERMUX_PUBLIC_KEY}" != ecdsa-sha2-*\ * ]]; then
  die "TERMUX_PUBLIC_KEY does not look like an SSH public key."
fi

export DEBIAN_FRONTEND=noninteractive
log "Installing required packages."
apt-get update -y
apt-get install -y ca-certificates curl openssh-server procps
if apt-cache show fastfetch >/dev/null 2>&1; then
  apt-get install -y fastfetch || true
elif apt-cache show neofetch >/dev/null 2>&1; then
  apt-get install -y neofetch || true
fi

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
command -v tailscaled >/dev/null 2>&1 || die "Tailscale installation did not provide the tailscaled daemon."

# Always use one explicit socket path. This prevents tailscale CLI and
# tailscaled from talking to different sockets on container-style VPS hosts.
tailscale_cli() {
  tailscale --socket="${TAILSCALE_SOCKET}" "$@"
}

daemon_ready() {
  [[ -S "${TAILSCALE_SOCKET}" ]] || return 1
  local status_output
  status_output="$(tailscale_cli status 2>&1 || true)"
  [[ "${status_output}" != *"failed to connect"* \
    && "${status_output}" != *"dial unix"* \
    && "${status_output}" != *"connection refused"* \
    && "${status_output}" != *"No such file"* ]]
}

wait_for_daemon() {
  local max_attempts="${1:-30}"
  local attempt
  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    if daemon_ready; then
      return 0
    fi
    if (( attempt % 5 == 0 )); then
      log "Still waiting for tailscaled socket (${attempt}/${max_attempts}s)."
    fi
    sleep 1
  done
  return 1
}

start_direct_daemon() {
  install -d -m 755 "$(dirname "${TAILSCALE_STATE}")" "$(dirname "${TAILSCALE_SOCKET}")"
  local daemon_args=(--state="${TAILSCALE_STATE}" --socket="${TAILSCALE_SOCKET}")
  if [[ "${TAILSCALE_USERSPACE}" -eq 1 ]]; then
    daemon_args+=(--tun=userspace-networking
      --socks5-server=localhost:1055
      --outbound-http-proxy-listen=localhost:1055)
  fi
  nohup tailscaled "${daemon_args[@]}" \
    >"${TAILSCALE_LOG}" 2>&1 </dev/null &
}

stop_unready_daemon() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop tailscaled 2>/dev/null || true
  fi
  if command -v service >/dev/null 2>&1; then
    service tailscaled stop 2>/dev/null || true
  fi
  if pgrep -x tailscaled >/dev/null 2>&1; then
    pkill -x tailscaled 2>/dev/null || true
    sleep 2
  fi
}

start_tailscaled() {
  if daemon_ready; then
    return 0
  fi

  log "Starting tailscaled and waiting for its control socket."

  # Container VPSes usually cannot use the kernel TUN device. Starting the
  # distro systemd unit first would launch a non-userspace daemon that can
  # fail silently, so use the known-good userspace command immediately.
  if [[ "${TAILSCALE_USERSPACE}" -eq 1 ]]; then
    log "Container mode: starting tailscaled with userspace networking directly."
    stop_unready_daemon
    start_direct_daemon
    if wait_for_daemon 30; then
      return 0
    fi
  else
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now tailscaled 2>/dev/null || true
    fi
    if wait_for_daemon 15; then
      return 0
    fi

    if command -v service >/dev/null 2>&1; then
      service tailscaled start 2>/dev/null || true
    fi
    if wait_for_daemon 15; then
      return 0
    fi

    log "Distro-managed tailscaled is not ready; switching to a direct daemon."
    stop_unready_daemon
    start_direct_daemon
    if wait_for_daemon 30; then
      return 0
    fi
  fi

  log "tailscaled did not become ready. Recent daemon log:"
  tail -40 "${TAILSCALE_LOG}" 2>/dev/null || true
  log "Process state:"
  pgrep -af tailscaled 2>/dev/null || true
  die "Could not start a usable tailscaled control socket at ${TAILSCALE_SOCKET}."
}

read_tty() {
  local prompt="$1"
  local value
  [[ -r /dev/tty ]] || die "Interactive setup needs a TTY. Set TAILSCALE_AUTH_KEY for non-interactive setup."
  printf '%s' "${prompt}" >/dev/tty
  IFS= read -r value </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "${value}"
}

read_secret_tty() {
  local prompt="$1"
  local value
  [[ -r /dev/tty ]] || die "Interactive setup needs a TTY. Set TAILSCALE_AUTH_KEY for non-interactive setup."
  printf '%s' "${prompt}" >/dev/tty
  IFS= read -r -s value </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "${value}"
}

start_tailscaled

run_auth_key_login() {
  local attempt
  for attempt in 1 2 3; do
    log "Joining Tailscale automatically as ${TAILSCALE_HOSTNAME} (attempt ${attempt}/3)."
    if tailscale_cli up --auth-key="${TAILSCALE_AUTH_KEY}" --hostname="${TAILSCALE_HOSTNAME}" --ssh=false; then
      unset TAILSCALE_AUTH_KEY
      return 0
    fi
    log "Tailscale auth-key setup failed; checking the daemon and retrying."
    start_tailscaled
    sleep 2
  done
  unset TAILSCALE_AUTH_KEY
  die "Tailscale auth-key setup failed after three attempts."
}

run_browser_login() {
  local attempt
  for attempt in 1 2 3; do
    log "Starting interactive Tailscale login. Open the URL printed below in any browser."
    if tailscale_cli up --hostname="${TAILSCALE_HOSTNAME}" --ssh=false; then
      return 0
    fi
    log "The login command failed; checking the daemon and retrying."
    start_tailscaled
    sleep 2
  done
  die "Tailscale browser login could not start after three attempts."
}

if tailscale_cli ip -4 >/dev/null 2>&1; then
  log "Tailscale is already connected; keeping the existing node login."
  tailscale_cli set --hostname="${TAILSCALE_HOSTNAME}" 2>/dev/null || true
else
  if [[ -z "${TAILSCALE_AUTH_KEY}" ]]; then
    printf '\nTailscale setup options:\n' >/dev/tty
    printf '  1) Paste a Tailscale auth key for automatic setup\n' >/dev/tty
    printf '  2) Use a Tailscale login URL\n\n' >/dev/tty
    choice="$(read_tty 'Choose 1 or 2 [default: 2]: ')"
    choice="${choice:-2}"
    case "${choice}" in
      1)
        TAILSCALE_AUTH_KEY="$(read_secret_tty 'Paste Tailscale auth key (hidden): ')"
        [[ -n "${TAILSCALE_AUTH_KEY}" ]] || die "No auth key was provided."
        ;;
      2)
        run_browser_login
        ;;
      *)
        die "Choose 1 or 2."
        ;;
    esac
  fi

  if [[ -n "${TAILSCALE_AUTH_KEY}" ]]; then
    run_auth_key_login
  fi
fi

wait_for_tailscale_ip() {
  local ip=""
  local attempt
  for attempt in $(seq 1 60); do
    ip="$(tailscale_cli ip -4 2>/dev/null | head -n 1 || true)"
    if [[ -n "${ip}" ]]; then
      printf '%s' "${ip}"
      return 0
    fi
    sleep 5
  done
  return 1
}

TAILSCALE_IP="$(wait_for_tailscale_ip || true)"
if [[ -z "${TAILSCALE_IP}" ]]; then
  log "Tailscale did not return an IPv4 address. Current status:"
  tailscale_cli status 2>&1 || true
  die "Complete the browser login, then rerun this same command."
fi

configure_userspace_ssh() {
  [[ "${TAILSCALE_USERSPACE}" -eq 1 ]] || return 0
  log "Configuring Tailscale Serve TCP ${TAILSCALE_SSH_PORT} -> local SSH port 22."
  local attempt
  for attempt in 1 2 3; do
    if tailscale_cli serve --bg --tcp "${TAILSCALE_SSH_PORT}" 22; then
      return 0
    fi
    log "Tailscale Serve setup failed; retrying (${attempt}/3)."
    sleep 2
  done
  tailscale_cli serve status 2>&1 || true
  die "Could not expose SSH through Tailscale Serve on port ${TAILSCALE_SSH_PORT}."
}

configure_userspace_ssh

install_login_banner() {
  local banner_file="/etc/profile.d/tealscale-connect.sh"
  local marker_begin='# >>> tealscale-connect login banner >>>'
  local marker_end='# <<< tealscale-connect login banner <<<'
  local root_home user_home rc_file prompt_id_file prompt_id=""

  prompt_id_file="/etc/tealscale-connect-id"
  if [[ -s "${prompt_id_file}" ]]; then
    prompt_id="$(tr -dc 'a-f0-9' < "${prompt_id_file}")"
    prompt_id="${prompt_id:0:6}"
  fi
  if [[ "${#prompt_id}" -ne 6 ]]; then
    prompt_id="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s\n' "${prompt_id}" > "${prompt_id_file}"
    chmod 644 "${prompt_id_file}"
  fi

  cat > "${banner_file}" <<BANNER
#!/usr/bin/env bash
# Generated by tealscale-connect. Safe to source from login shells.
case "\${-}" in *i*) ;; *) return 0 ;; esac
[[ -t 1 ]] || return 0
if [[ -n "\${TEALSCALE_CONNECT_BANNER_SHOWN:-}" ]]; then return 0; fi
TEALSCALE_CONNECT_BANNER_SHOWN=1
TS_SOCKET='${TAILSCALE_SOCKET}'
TS_PORT='${TAILSCALE_SSH_PORT}'
TS_USERSPACE='${TAILSCALE_USERSPACE}'
TS_PROMPT_ID='${prompt_id}'
TS_IP="\$(tailscale --socket="\${TS_SOCKET}" ip -4 2>/dev/null | head -n 1 || true)"
TS_PROMPT_IP="\${TS_IP:-${TAILSCALE_IP}}"
TS_PROMPT_IP="\${TS_PROMPT_IP//./-}"
TS_PROMPT_HOST="ip-\${TS_PROMPT_IP}-\${TS_PROMPT_ID}"
if [[ "\${EUID}" -eq 0 ]]; then
  PS1='\u@'"\${TS_PROMPT_HOST}"':\w# '
else
  PS1='\u@'"\${TS_PROMPT_HOST}"':\w$ '
fi
printf '\n[tealscale-connect] Login working.\n'
if [[ -n "\${TS_IP}" ]]; then
  printf '[tealscale-connect] Tailscale IP: %s\n' "\${TS_IP}"
  if [[ "\${TS_USERSPACE}" == '1' ]]; then
    printf '[tealscale-connect] SSH: ssh -p %s root@%s\n' "\${TS_PORT}" "\${TS_IP}"
  else
    printf '[tealscale-connect] SSH: ssh root@%s\n' "\${TS_IP}"
  fi
else
  printf '[tealscale-connect] Tailscale: waiting/not connected\n'
fi
if command -v fastfetch >/dev/null 2>&1; then
  fastfetch
elif command -v neofetch >/dev/null 2>&1; then
  neofetch
else
  printf '[tealscale-connect] System: %s\n' "\$(uname -srmo 2>/dev/null || true)"
  printf '[tealscale-connect] Memory: '; free -h 2>/dev/null | awk '/^Mem:/ {print \$3 " used / " \$2}'
  printf '[tealscale-connect] Disk: '; df -h / 2>/dev/null | awk 'NR==2 {print \$3 " used / " \$2 " (" \$5 ")"}'
fi
BANNER
  chmod 644 "${banner_file}"

  install_bashrc_hook() {
    rc_file="$1"
    [[ -n "${rc_file}" ]] || return 0
    touch "${rc_file}"
    if ! grep -Fq "${marker_begin}" "${rc_file}"; then
      cat >> "${rc_file}" <<HOOK

${marker_begin}
if [[ -r /etc/profile.d/tealscale-connect.sh ]]; then
  . /etc/profile.d/tealscale-connect.sh
fi
${marker_end}
HOOK
    fi
  }

  root_home="$(getent passwd root | cut -d: -f6)"
  install_bashrc_hook "${root_home}/.bashrc"
  if [[ -n "${SSH_USER}" ]]; then
    user_home="$(getent passwd "${SSH_USER}" | cut -d: -f6)"
    install_bashrc_hook "${user_home}/.bashrc"
  fi
  log "Configured login banner and fastfetch/neofetch for root and available login shells."
}

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

install_login_banner

if command -v systemctl >/dev/null 2>&1; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi

printf '\nSetup complete.\n'
printf 'Tailscale hostname: %s\n' "${TAILSCALE_HOSTNAME}"
printf 'Tailscale IPv4: %s\n' "${TAILSCALE_IP}"
printf '\nConnect from Termux:\n'
if [[ "${TAILSCALE_USERSPACE}" -eq 1 ]]; then
  printf '  ssh -p %s root@%s\n' "${TAILSCALE_SSH_PORT}" "${TAILSCALE_IP}"
  printf '\nIf you want to select the key explicitly:\n'
  printf '  ssh -p %s -i ~/.ssh/id_ed25519 root@%s\n' "${TAILSCALE_SSH_PORT}" "${TAILSCALE_IP}"
else
  printf '  ssh root@%s\n' "${TAILSCALE_IP}"
  printf '\nIf you want to select the key explicitly:\n'
  printf '  ssh -i ~/.ssh/id_ed25519 root@%s\n' "${TAILSCALE_IP}"
fi
