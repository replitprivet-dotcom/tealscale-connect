# tealscale-connect

A secure, idempotent bootstrap for configuring a fresh Ubuntu or Debian VPS for **Tailscale-based SSH access**. The installer installs Tailscale and OpenSSH, starts and verifies `tailscaled`, supports either an auth-key or browser-login flow, authorizes the Termux public key, and prints the final `ssh root@<tailscale-ip>` command.

> **Important:** This public repository contains no GitHub token, Tailscale auth key, Tailscale API key, private key, or VPS password. Secrets are accepted only at runtime.

## Automatic behavior

The installer is designed for the container-style VPS environment that caused the earlier `failed to connect to local tailscaled` error. It uses one explicit control socket for the CLI and daemon, then performs the following steps:

1. Installs the required packages and starts the SSH service.
2. Installs Tailscale when it is missing.
3. Detects whether `/dev/net/tun` is available. On container VPSes without it, automatically starts Tailscale in userspace networking mode and prepares a TCP Serve mapping from port `2222` to local SSH port `22`.
4. Starts `tailscaled` through systemd when available, then through the service manager, and finally as a direct background process when the VPS has no working systemd PID 1.
5. Waits for the control socket to become usable before calling `tailscale up`.
6. Supports two authentication modes. An auth key can be supplied non-interactively or pasted into a hidden prompt; alternatively, the script starts the browser-login flow and displays the URL from Tailscale.
7. Retries authentication up to three times after daemon or socket failures.
8. Waits for a Tailscale IPv4 address, adds the Termux public key idempotently, reloads SSH, and prints the exact SSH commands.
9. Installs `fastfetch` when available, with `neofetch` and a lightweight system-summary fallback.
10. Installs an idempotent `/etc/profile.d/tealscale-connect.sh` banner so interactive root and `su` login shells show a working message, Tailscale IP, SSH command, and system summary.
11. On failure, prints the current Tailscale status, daemon process state, and recent daemon log lines without printing the auth key.

Rerunning the installer is safe. Existing Tailscale connections are kept, duplicate authorized-key lines are not added, and the hostname is updated without recreating the node unnecessarily.

The script does **not** generate a Tailscale API key. For automatic node registration, use a Tailscale **auth key**. For the browser flow, no auth key is needed; complete the URL login and let the script continue. An auth key registers a node, while an API key is intended for administrative API operations.

## Fresh VPS usage

On the new VPS, run exactly these two commands as root:

```bash
apt-get update -y && apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/replitprivet-dotcom/tealscale-connect/main/install-tailscale.sh | bash
```

After the second command starts, choose one of the displayed options:

| Choice | Result |
|---|---|
| `1` | Paste a Tailscale auth key into a hidden prompt. Registration is automatic. |
| `2` | Tailscale prints a browser login URL. Complete login, then the script continues automatically. |

When provisioning finishes, the output includes the SSH command. On a normal VPS with `/dev/net/tun`, it is:

```bash
ssh root@<tailscale-ip>
```

On a container VPS without `/dev/net/tun`, the script automatically configures Tailscale Serve and prints:

```bash
ssh -p 2222 root@<tailscale-ip>
```

It also prints an explicit-key alternative for each mode. The plain command works when the private key is stored at Termux's default path `~/.ssh/id_ed25519`. The script authorizes the bundled public key, which is the current Termux key used for this setup.

On every interactive SSH or `su` shell, the installer shows a small status banner such as:

```text
[tealscale-connect] Login working.
[tealscale-connect] Tailscale IP: 100.x.x.x
[tealscale-connect] SSH: ssh -p 2222 root@100.x.x.x
```

It then runs `fastfetch`, `neofetch`, or a built-in lightweight system summary. The shell prompt is also changed automatically to include the Tailscale IP and a persistent six-character ID. For example:

```text
root@ip-100-124-33-109-a1b2c3:~#
```

The same prompt and banner are applied to root and configured `su`/login shells. The banner is marker-protected, so rerunning the installer does not add duplicate shell hooks.

## Fully non-interactive mode

For automation, pass the auth key through the environment. Do not put a real key into the repository, a public URL, or shell history if it can be avoided:

```bash
export TAILSCALE_AUTH_KEY='tskey-auth-REPLACE_ME'
export TAILSCALE_HOSTNAME='my-new-vps'
curl -fsSL https://raw.githubusercontent.com/replitprivet-dotcom/tealscale-connect/main/install-tailscale.sh | bash
```

You can replace the bundled public key at runtime:

```bash
export TERMUX_PUBLIC_KEY='ssh-ed25519 REPLACE_WITH_YOUR_TERMUX_PUBLIC_KEY'
```

For an additional non-root account, set `SSH_USER` before running the script:

```bash
export SSH_USER='ubuntu'
```

Root access is still configured because the intended command is `ssh root@<tailscale-ip>`.

## If a run is interrupted

Press `Ctrl+C` and rerun the same two commands. The script is designed to recover a stale or missing daemon socket automatically. If the VPS has a severe daemon or kernel limitation, the final diagnostics show:

```bash
pgrep -af tailscaled
cat /var/log/tailscaled.log
```

The script itself prints recent log lines when it cannot establish the control socket or obtain a Tailscale IPv4 address.

## Secret-handling rules

Keep `TAILSCALE_AUTH_KEY` out of shell history where practical, never commit it, and revoke or rotate it after provisioning if it is single-use or no longer needed. Keep the Termux private key only on the phone; only the public key belongs in `authorized_keys`. Do not place a GitHub token, Tailscale API key, auth key, private SSH key, or VPS password in this public repository.

## Files

| File | Purpose |
|---|---|
| `install-tailscale.sh` | Idempotent VPS bootstrap with daemon recovery, authentication retries, diagnostics, SSH output, and login-shell setup. |
| `diagnose-tailscale.sh` | Read-only daemon, socket, Tailscale, SSH, and log diagnostics. |
| `.env.example` | Safe placeholder template for local runtime variables. |
| `.gitignore` | Prevents local secret files, private keys, and runtime logs from being committed. |

## License

This repository is provided as-is for personal infrastructure provisioning. Review the script before running it on a production VPS.
