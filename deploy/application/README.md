---
description: "Build and deploy the daidai fork as a persistent Web service accessed through SSH."
---

# Application deployment

English | [中文](README.zh.md)

## Summary

This tutorial starts with the [initialized server](../README.md), a working deploy SSH login, and this fork checked out locally. It builds the fork's source, publishes a tested image to GHCR, and runs one Web instance with persistent data. Model credentials are entered in Web settings after login; they never belong in the image or Git.

## Table of Contents

- [Build and verify](#build-and-verify)
- [Publish and deploy](#publish-and-deploy)
- [Open the Web application](#open-the-web-application)
- [Update and recover](#update-and-recover)
- [Dev Note](#dev-note)

<a id="build-and-verify"></a>

## Build and verify

Run these commands from the repository root on a computer with Docker, Python 3, and enough memory for the upstream build. The 2-core, 4GB deployment server only pulls and runs images. Use a clean committed tree for a release so the image's revision identifies its source.

```bash
docker build --platform linux/amd64 \
  --build-arg SOURCE_COMMIT="$(git rev-parse HEAD)" \
  -f deploy/Dockerfile -t daidai:check .
python3 deploy/smoke_image.py daidai:check
```

The Dockerfile pins base image digests and pnpm, installs the frozen lockfile, runs the upstream artifact build and aggregate type checks, builds Linux sandbox binaries, and retains the compiled workspace and its installed dependencies so dynamically loaded Web plugins keep their peer resolution. The runtime image includes source and development dependencies; Git metadata, local environment files, and private-key files are excluded from the build context. Debian packages still resolve from current repositories; the resulting published image digest identifies the deployed bytes. The smoke check uses disposable Docker resources and tests anonymous rejection, token login, frontend assets, UID 1001, and a persistent marker across restart and container recreation. It does not call a model or prove scheduled tasks resume.

<a id="publish-and-deploy"></a>

## Publish and deploy

The [image workflow](../../.github/workflows/daidai-image.yml) builds Linux amd64 on pushes to this fork's master or manual dispatch, runs the smoke check, then publishes `ghcr.io/isaac-zheng/daidai:sha-COMMIT`. A failed build or smoke prevents publication. Repository-specific upstream workflows may require upstream runners; this workflow uses GitHub's standard Ubuntu runner.

Record the digest printed by `docker push`. Ensure the GHCR package permits this server to pull: public packages need no login; private packages require a separate read-only package credential on the server. Copy the Compose file from your Mac, replacing `SERVER_IP` with the server address.

```bash
scp -i "$HOME/.ssh/personal-agent-server.pem" deploy/compose.yaml \
  deploy@SERVER_IP:/opt/daidai/compose.yaml
ssh -i "$HOME/.ssh/personal-agent-server.pem" deploy@SERVER_IP
```

On the server, verify that `id -u deploy` and `id -g deploy` are both 1001; otherwise adapt the image user and directory ownership before starting. Create `/opt/daidai/.env` with the actual published digest, then pull and start.

```bash
cd /opt/daidai
printf '%s\n' 'DAIDAI_IMAGE=ghcr.io/isaac-zheng/daidai@sha256:REPLACE_WITH_DIGEST' > .env
chmod 600 .env
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=80 agent
```

Compose binds only `127.0.0.1:3080` on the server, restarts the service unless explicitly stopped, and allows 60 seconds for shutdown. `/opt/daidai/data` stores `DSH_HOME`, including settings and sessions; `/opt/daidai/workspace` stores task files. The agent runs as UID/GID 1001 without host Docker access. The entrypoint pins the upstream in-browser directory picker overlay, allowing directory selection without a desktop on the server. Container restart policy does not restart an unhealthy but running process and does not prove interrupted model turns resume.

<a id="open-the-web-application"></a>

## Open the Web application

Keep this command running in a Mac terminal. SSH reports an error if the local port is already occupied.

```bash
ssh -CN -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -i "$HOME/.ssh/personal-agent-server.pem" \
  -L 127.0.0.1:3080:127.0.0.1:3080 deploy@SERVER_IP
```

Open the `http://127.0.0.1:3080/?token=...` URL printed in the server logs. Treat that URL as a login credential. After a process restart, use its new URL if authentication is requested. Enter your provider credentials in Web settings, select `/workspace` for work, and send a short task. Keep port 3080 closed in the cloud firewall; no domain or public Web port is needed for this SSH-only setup.

<a id="update-and-recover"></a>

## Update and recover

Before an upgrade, stop the service and take a consistent backup of `data`, `workspace`, `.env`, and `compose.yaml` outside the agent's writable directories. Keep credentials protected. Record the old image digest; then change `.env` to the new verified digest, pull, and start. Confirm browser login, existing sessions, a model response, and a scheduled wake-up. Backups and scheduling are not enabled by this deployment procedure.

If the new version fails, stop it and inspect logs locally. Reverting only the image can be unsafe after a data migration; restore the matching pre-upgrade data backup and old digest together. Do not remove application directories or run volume cleanup as a repair. First deployment and upgrades need separate evidence for browser access, model calls, scheduled tasks, and reboot recovery.

<a id="dev-note"></a>

## Dev Note

On 2026-10-26, the Linux amd64 image passed all 10 upstream build checks and the container smoke: plugin activation, login, invalid-token rejection, frontend assets, UID 1001, restart, and data retention after container recreation. Its uncompressed size is approximately 2.8GB. GitHub Actions published the image, and the server successfully pulled it anonymously and started it by digest. Web login, selecting /workspace, and a real DeepSeek-V4.1-Flash reply passed through an SSH tunnel. After restarting the server container, the same conversation and provider configuration remained usable and a second real model reply passed. An SSH tunnel with compression improved this local access path. The deployed digest is `sha256:cc1fc86b12408b6dabb5e374478cbf1caad7429f2425be48f8e52fe04b36f205`; [the publishing run](https://github.com/isaac-zheng/daidai/actions/runs/40322557587) records its build and smoke checks. Whole-server reboot, scheduled wake-up, and a 24-hour soak have not been tested. The server bootstrap evidence is recorded in [Server initialization](../README.md#dev-note).
