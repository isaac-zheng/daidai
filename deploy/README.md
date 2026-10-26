---
description: "Prepare a Debian 13 amd64 server for daidai with Docker, an SSH deployment account, and application directories."
---

# Server initialization

English | [中文](README.zh.md)

## Summary

[bootstrap.sh](bootstrap.sh) prepares a dedicated Debian 13 amd64 systemd server. Run it as root with one OpenSSH public key. `--check` only reads local prerequisites; `--apply` changes the host. This procedure does not deploy Harness.

[Application deployment](application/README.md)

## Table of Contents

- [Check prerequisites](#check-prerequisites)
- [Apply initialization](#apply-initialization)
- [Verify access](#verify-access)
- [Changes and recovery](#changes-and-recovery)
- [Local checks](#local-checks)
- [Dev Note](#dev-note)

<a id="check-prerequisites"></a>

## Check prerequisites

Verify the server's SSH host fingerprint through the cloud console before connecting. Retain a working root login throughout initialization. The input must contain exactly one public key without `authorized_keys` options; private keys remain on the local computer.

With a verified SSH connection, stream the script from the repository root to check the server without copying files. Replace `SERVER_IP`; this example reuses the public key already authorized for root.

```bash
ssh -i "$HOME/.ssh/personal-agent-server.pem" root@SERVER_IP \
  'bash -s -- --check /root/.ssh/authorized_keys' < deploy/bootstrap.sh
```

`Preflight passed` confirms local prerequisites only. It does not test package downloads, Docker startup, or a new deploy login. If root has multiple authorized keys, supply a separate single-key public file instead.

<a id="apply-initialization"></a>

## Apply initialization

After reviewing [bootstrap.sh](bootstrap.sh), run the same command with `--apply`. This command changes the server; keep the root connection available until the new deployment login passes verification.

```bash
ssh -i "$HOME/.ssh/personal-agent-server.pem" root@SERVER_IP \
  'bash -s -- --apply /root/.ssh/authorized_keys' < deploy/bootstrap.sh
```

The `deploy` account receives membership in the Docker group, which grants effective root administration through Docker. It has no sudo rule or login password configured by this script. Do not use this account as the agent's execution identity or give the agent the host Docker socket.

<a id="verify-access"></a>

## Verify access

Open a new local terminal and verify the deployment account before changing root access. A successful check must show `deploy`, the Docker server version, and the Compose version.

```bash
ssh -i "$HOME/.ssh/personal-agent-server.pem" deploy@SERVER_IP \
  'whoami; docker version --format "{{.Server.Version}}" && docker compose version'
```

<a id="changes-and-recovery"></a>

## Changes and recovery

- The script installs CA certificates, curl, Git, OpenSSH client, Docker Engine/CLI, containerd.io, Buildx, and Compose from Debian and the [official Docker repository](https://docs.docker.com/engine/install/debian/). It selects repository versions on first installation and uses `--no-upgrade` on repeat runs; it is not a version lock. Docker component versions are recorded in `/var/lib/daidai-bootstrap/packages.tsv` after success.
- Docker starts automatically. New containers default to the `local` log driver with three 10MB files per container; this limits stdout/stderr logs, not application files or the total disk usage. [Docker log rotation](https://docs.docker.com/engine/logging/drivers/local/) owns the details.
- The script appends the supplied public key without replacing existing keys and creates `/opt/daidai/{config,data,workspace}` owned by `deploy` when absent. Existing application directory ownership and data remain unchanged. Container UID mapping belongs to the application deployment configuration.
- Different existing Docker configuration, unsupported account settings, symlinked managed paths, and conflicting distro packages cause an error. Review the named path or package manually; the script does not uninstall packages or overwrite different configurations.
- Failures stop execution without rolling back completed changes. Resolve the reported cause, run `--check`, and retry `--apply`. The script leaves SSH policy, root access, cloud firewall settings, swap, timezone, and system-wide upgrades untouched. It does not reboot or explicitly restart Docker; package installation may start services and Docker may manage its own network rules.

<a id="local-checks"></a>

## Local checks

Run from the repository root with Bash, Python 3, and OpenSSH installed. [test_bootstrap.py](test_bootstrap.py) checks input rejection and preservation of existing keys/configuration without root access. ShellCheck is an additional static check when installed.

```bash
bash -n deploy/bootstrap.sh
python3 deploy/test_bootstrap.py
shellcheck deploy/bootstrap.sh
```

<a id="dev-note"></a>

## Dev Note

On 2026-10-26, a Debian 13.2 amd64 server passed preflight, initial apply, repeat apply, fresh deploy SSH login, and `docker run --rm hello-world`. Docker 29.9.2, Compose 5.6.1, Buildx 0.38.1, and containerd.io 2.4.2 were installed. Repeat apply changed no package versions, authorized-key content, Docker configuration, account IDs, application directory permissions, or Docker process/start timestamp. The deployment account's UID/GID is 1001 on this host; resolve IDs on each host before configuring application mounts. Docker is enabled at boot; a server reboot has not been tested. Application acceptance is recorded in [Application deployment](application/README.md#dev-note). Local helper tests, ShellCheck, and repository lint passed. Dependency installation required NODE_USE_ENV_PROXY=1 on the local machine. Documentation quick checks passed 20 of 21 gates; doc-sync passed 42 of 43 after clearing the SOCKS-only ALL_PROXY variables. The remaining repository-reference gate mistakes a file size in the unchanged Python lockfile for a commit identifier.
