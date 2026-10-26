#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_USER=deploy
APP_ROOT=/opt/daidai
DOCKER_CONFIG='{"log-driver":"local","log-opts":{"max-size":"10m","max-file":"3"}}'
DOCKER_SOURCE='Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc'

fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

usage() {
  cat <<'EOF'
Usage: bash bootstrap.sh --check PUBLIC_KEY_FILE
       bash bootstrap.sh --apply PUBLIC_KEY_FILE

Debian 13 amd64, root, systemd, and a single OpenSSH public key required.
--check reads local prerequisites without installing or changing anything.
--apply installs Docker/Compose, creates deploy, and prepares /opt/daidai.
deploy receives Docker administration (equivalent to root), not sudo access.
EOF
}

validate_key() {
  local key_file=$1 count
  [[ -f "$key_file" && -r "$key_file" ]] || { fail "Public key is not readable: $key_file"; return 1; }
  count=$(awk 'NF {n++} END {print n+0}' "$key_file")
  [[ "$count" == 1 ]] || { fail 'Supply exactly one public key.'; return 1; }
  grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( .*)?$' "$key_file" || {
    fail 'Expected an OpenSSH public key, without authorized_keys options; never supply a private key.'; return 1;
  }
  ssh-keygen -lf "$key_file" >/dev/null || { fail 'Invalid SSH public key.'; return 1; }
}

check_file() {
  local path=$1 expected=$2
  [[ ! -L "$path" ]] || { fail "Refusing symlink: $path"; return 1; }
  if [[ -e "$path" ]]; then
    if [[ ! -f "$path" ]] || ! cmp -s "$path" <(printf '%s\n' "$expected"); then
      fail "Existing file differs; review it manually before retrying: $path"; return 1
    fi
  fi
}

installed() {
  [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == 'install ok installed' ]]
}

preflight() {
  local key_file=$1 path package account _name _password uid _gid _gecos account_home account_shell
  [[ $EUID == 0 ]] || { fail 'Run on the server as root.'; return 1; }
  [[ $(uname -s) == Linux ]] || { fail 'Run on the Debian server, not on macOS.'; return 1; }
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "$ID" == debian && "$VERSION_ID" == 13 && $(dpkg --print-architecture) == amd64 ]] || {
    fail 'This bootstrap supports Debian 13 amd64 only.'; return 1;
  }
  [[ -d /run/systemd/system ]] || { fail 'A systemd host is required.'; return 1; }
  command -v flock >/dev/null || { fail 'Install util-linux before retrying.'; return 1; }
  command -v ssh-keygen >/dev/null || { fail 'Install openssh-client before retrying.'; return 1; }
  validate_key "$key_file" || return 1
  for path in /home/deploy /home/deploy/.ssh "$APP_ROOT" "$APP_ROOT/config" "$APP_ROOT/data" "$APP_ROOT/workspace" /etc/docker /etc/apt/keyrings; do
    [[ ! -L "$path" && ( ! -e "$path" || -d "$path" ) ]] || { fail "Expected a real directory: $path"; return 1; }
  done
  path=/home/deploy/.ssh/authorized_keys
  [[ ! -L "$path" && ( ! -e "$path" || -f "$path" ) ]] || { fail "Expected a regular file: $path"; return 1; }
  check_file /etc/docker/daemon.json "$DOCKER_CONFIG" || return 1
  check_file /etc/apt/sources.list.d/docker.sources "$DOCKER_SOURCE" || return 1
  [[ ! -e /etc/apt/sources.list.d/docker.list ]] || { fail 'Review existing docker.list before using this bootstrap.'; return 1; }
  [[ ! -L /etc/apt/keyrings/docker.asc ]] || { fail 'Refusing a symlink at docker.asc.'; return 1; }
  if account=$(getent passwd "$DEPLOY_USER"); then
    IFS=: read -r _name _password uid _gid _gecos account_home account_shell <<< "$account"
    [[ "$uid" -ge 1000 && "$account_home" == /home/deploy && "$account_shell" == /bin/bash ]] || {
      fail 'Existing deploy account has an unexpected UID, home, or shell; review it manually.'; return 1;
    }
  fi
  for package in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
    if installed "$package"; then fail "Conflicting package: $package; no packages were removed."; return 1; fi
  done
  if installed docker-ce && [[ ! -f /etc/docker/daemon.json ]]; then
    fail 'Existing Docker installation has no managed logging configuration; review it manually.'; return 1
  fi
}

add_public_key() {
  local key_file=$1 target=$2 key_type key_blob _key_comment
  read -r key_type key_blob _key_comment < <(awk 'NF {print; exit}' "$key_file")
  if [[ -f "$target" ]] && awk -v type="$key_type" -v blob="$key_blob" '$1 == type && $2 == blob {found=1} END {exit !found}' "$target"; then
    return
  fi
  # Preserve existing keys, including a final line without a newline.
  if [[ -s "$target" && -n $(tail -c 1 "$target") ]]; then printf '\n' >> "$target"; fi
  awk 'NF {print; exit}' "$key_file" >> "$target"
}

apply() {
  local key_file=$1 package
  exec 9>/run/lock/daidai-bootstrap.lock
  flock -n 9 || { fail 'Another bootstrap is running; wait for it to finish.'; return 1; }
  preflight "$key_file"
  umask 022
  BOOTSTRAP_TEMP=$(mktemp -d)
  trap 'rm -rf -- "$BOOTSTRAP_TEMP"' EXIT
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-upgrade ca-certificates curl git openssh-client
  install -d -m 0755 /etc/apt/keyrings /etc/docker
  if [[ ! -e /etc/apt/keyrings/docker.asc ]]; then
    curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
      --connect-timeout 15 --max-time 120 --retry 2 \
      https://download.docker.com/linux/debian/gpg -o "$BOOTSTRAP_TEMP/docker.asc"
    install -m 0644 "$BOOTSTRAP_TEMP/docker.asc" /etc/apt/keyrings/docker.asc
  fi
  if [[ ! -e /etc/apt/sources.list.d/docker.sources ]]; then
    printf '%s\n' "$DOCKER_SOURCE" > /etc/apt/sources.list.d/docker.sources
  fi
  if [[ ! -e /etc/docker/daemon.json ]]; then
    printf '%s\n' "$DOCKER_CONFIG" > /etc/docker/daemon.json
  fi
  apt-get update
  apt-get install -y --no-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker info >/dev/null
  [[ $(docker info --format '{{.LoggingDriver}}') == local ]] || {
    fail 'Docker has not loaded the local logging driver; review before restarting Docker manually.'; return 1;
  }
  docker compose version
  docker buildx version
  if ! getent passwd "$DEPLOY_USER" >/dev/null; then
    useradd --create-home --user-group --shell /bin/bash "$DEPLOY_USER"
  fi
  usermod -aG docker "$DEPLOY_USER"
  install -d -m 0700 -o "$DEPLOY_USER" -g "$(id -gn "$DEPLOY_USER")" /home/deploy/.ssh
  add_public_key "$key_file" /home/deploy/.ssh/authorized_keys
  chown "$DEPLOY_USER:$(id -gn "$DEPLOY_USER")" /home/deploy/.ssh/authorized_keys
  chmod 0600 /home/deploy/.ssh/authorized_keys
  for package in "$APP_ROOT" "$APP_ROOT/config" "$APP_ROOT/data" "$APP_ROOT/workspace"; do
    if [[ ! -e "$package" ]]; then
      install -d -m 0750 -o "$DEPLOY_USER" -g "$(id -gn "$DEPLOY_USER")" "$package"
    fi
  done
  install -d -m 0755 /var/lib/daidai-bootstrap
  dpkg-query -W -f='${Package}\t${Version}\n' docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /var/lib/daidai-bootstrap/packages.tsv
  runuser -u "$DEPLOY_USER" -- docker info >/dev/null
  printf 'Bootstrap complete. Test a NEW SSH login as deploy before changing root access.\n'
}

main() {
  if [[ $# == 1 && "$1" == --help ]]; then usage; return; fi
  [[ $# == 2 && ( "$1" == --check || "$1" == --apply ) ]] || { usage >&2; return 2; }
  preflight "$2"
  if [[ "$1" == --check ]]; then
    printf 'Preflight passed. Apply will install Docker/Compose, grant deploy Docker administration, and create /opt/daidai.\n'
    printf 'This check does not test package downloads or SSH login.\n'
  else
    apply "$2"
  fi
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  trap 'printf "Bootstrap stopped at line %s. Review the error above; applied changes are not rolled back.\n" "$LINENO" >&2' ERR
  main "$@"
fi
