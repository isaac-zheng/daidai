# syntax=docker/dockerfile:1
FROM node:24-bookworm@sha256:6449e19d8184d84062525b6a7524def03146c2cb04a7f08b076680d0e8e4240a AS build
ENV CI=true DSH_TELEMETRY_DISABLED=1 ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    DSH_GATE_CONCURRENCY=2 DSH_OXLINT_THREADS=2 NODE_USE_ENV_PROXY=1
RUN apt-get update && apt-get install -y --no-install-recommends musl-tools \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global pnpm@11.28.5
WORKDIR /src
COPY . .
ARG SOURCE_COMMIT
ENV DSH_CLIENT_COMMIT_HASH=${SOURCE_COMMIT}
RUN pnpm install --frozen-lockfile
RUN pnpm run build && node native/system/scripts/build.ts

FROM node:24-bookworm-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git openssh-client python3 ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1001 agent \
    && useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash agent \
    && mkdir -p /workspace /home/agent/.dsh \
    && chown agent:agent /workspace /home/agent/.dsh
ARG SOURCE_COMMIT
LABEL org.opencontainers.image.source="https://github.com/isaac-zheng/daidai" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}"
# Preserve pnpm's workspace links and peer resolution for dynamically loaded Web plugins.
COPY --from=build /src /app
COPY deploy/entrypoint.sh /usr/local/bin/daidai-entrypoint
ENV NODE_ENV=production DSH_HOME=/home/agent/.dsh DSH_TELEMETRY_DISABLED=1
USER 1001:1001
WORKDIR /workspace
EXPOSE 3080
ENTRYPOINT ["/bin/bash", "/usr/local/bin/daidai-entrypoint"]
