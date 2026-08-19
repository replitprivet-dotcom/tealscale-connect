# tealscale-connect

A small, secure bootstrap for configuring a fresh Ubuntu or Debian VPS for **Tailscale-based SSH access**. The script installs Tailscale, joins the VPS to your tailnet with a short-lived or reusable Tailscale auth key, enables the SSH service, authorizes a supplied Termux public key, and prints the final `ssh root@<tailscale-ip>` command.

> **Important:** This public repository intentionally contains no GitHub token, Tailscale auth key, API key, private key, or VPS password. Provide secrets through environment variables at runtime.

## What it does

The bootstrap performs the following deterministic steps:

1. Requires root privileges and installs or starts the SSH service.
2. Installs Tailscale using the official installation method when it is not already present.
3. If `TAILSCALE_AUTH_KEY` is supplied, joins the tailnet automatically.
4. Otherwise, shows two choices: paste an auth key securely at a hidden prompt, or start an interactive Tailscale login flow that prints a browser URL.
5. Adds the bundled Termux public key to the root account and, optionally, to `SSH_USER`.
6. Waits for the Tailscale IPv4 address and prints the exact `ssh root@<tailscale-ip>` command.

The script does **not** generate a Tailscale API key. For automatic mode, create a Tailscale **auth key** in the Tailscale admin console and paste it into the hidden prompt, or provide it through `TAILSCALE_AUTH_KEY`. For the login-URL mode, no auth key is needed: complete the browser login and let the script continue. An auth key registers a node; an API key is for administrative API operations and should not be embedded in a VPS bootstrap script.

## Fresh VPS usage

On the new VPS, run exactly these two commands as root:

```bash
apt-get update -y && apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/replitprivet-dotcom/tealscale-connect/main/install-tailscale.sh | bash
```

After the second command starts, the installer offers two Tailscale options. Choose **1** to paste an auth key into a hidden prompt for automatic setup, or choose **2** to receive a Tailscale login URL and authenticate in a browser. After login completes, the script automatically prints the Tailscale IPv4 address and the final SSH command.

The bundled public key is the current Termux key. To use a different key, set `TERMUX_PUBLIC_KEY` before launching the script. To use automatic mode without a prompt, set `TAILSCALE_AUTH_KEY` before the second command.

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
