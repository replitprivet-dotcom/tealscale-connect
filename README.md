# tealscale-connect

A small, secure bootstrap for configuring a fresh Ubuntu or Debian VPS for **Tailscale-based SSH access**. The script installs Tailscale, joins the VPS to your tailnet with a short-lived or reusable Tailscale auth key, enables the SSH service, authorizes a supplied Termux public key, and prints the final `ssh root@<tailscale-ip>` command.

> **Important:** This public repository intentionally contains no GitHub token, Tailscale auth key, API key, private key, or VPS password. Provide secrets through environment variables at runtime.

## What it does

The bootstrap performs the following deterministic steps:

1. Requires root privileges and validates the required runtime secrets.
2. Installs `openssh-server` when it is missing and starts the SSH service.
3. Installs Tailscale using the official installation method when it is not already present.
4. Joins the VPS to the selected tailnet using `TAILSCALE_AUTH_KEY`.
5. Adds `TERMUX_PUBLIC_KEY` to the root account and, optionally, to `SSH_USER`.
6. Prints the Tailscale IPv4 address and the exact SSH commands to use.

The script does **not** generate a Tailscale API key. A Tailscale auth key must be created in the Tailscale admin console or supplied by an existing provisioning system. An auth key is the credential intended for registering a node; an API key is for administrative API operations and should not be embedded in a VPS bootstrap script.

## Fresh VPS usage

On the new VPS, run the following as root. Replace the placeholder values locally; do not commit them to GitHub or paste them into public chat.

```bash
export TAILSCALE_AUTH_KEY='tskey-auth-REPLACE_ME'
export TERMUX_PUBLIC_KEY='ssh-ed25519 REPLACE_WITH_YOUR_TERMUX_PUBLIC_KEY'
export TAILSCALE_HOSTNAME='my-new-vps-ssh'

apt-get update -y && apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/replitprivet-dotcom/tealscale-connect/main/install-tailscale.sh | bash
```

After completion, the script prints the Tailscale IPv4 address. Connect from Termux with either command:

```bash
ssh root@<tailscale-ip>
```

or, explicitly selecting the default Ed25519 key:

```bash
ssh -i ~/.ssh/id_ed25519 root@<tailscale-ip>
```

The plain command works when the private key is stored at Termux's default path `~/.ssh/id_ed25519` and the public key was authorized by the script.

## Optional non-root account

To authorize the same public key for a non-root account as well, set `SSH_USER` before running the installer:

```bash
export SSH_USER='ubuntu'
curl -fsSL https://raw.githubusercontent.com/replitprivet-dotcom/tealscale-connect/main/install-tailscale.sh | bash
```

The script still configures root access because the intended provisioning flow uses `ssh root@<tailscale-ip>`.

## Secret-handling rules

Keep `TAILSCALE_AUTH_KEY` out of shell history where practical, never commit it, and revoke or rotate it after provisioning if it is single-use or no longer needed. Keep the Termux private key only on the phone; only the public key belongs in the VPS `authorized_keys` file. If a GitHub Actions workflow is added later, store the auth key and private deployment key as encrypted repository or environment secrets rather than plain YAML values.

## Files

| File | Purpose |
|---|---|
| `install-tailscale.sh` | Idempotent VPS bootstrap script. |
| `.gitignore` | Prevents local secret files and runtime artifacts from being committed. |

## License

This repository is provided as-is for personal infrastructure provisioning. Review the script before running it on a production VPS.
