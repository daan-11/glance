#!/usr/bin/env bash
# Copy deploy/helm/glance into /home/derksen/k3s/apps-helm/glance on the home-lab
# (flattened), bump the chart version, and push main as root.
# APPS_HELM_GIT_TOKEN is sent as HTTP Basic auth (user oauth2) on the raw origin URL.
# Glance has no image build: k3s pulls glanceapp/glance itself.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_SRC="${ROOT}/deploy/helm/glance"
HOST="${HOMELAB_HOST:-home-lab.vulture-qilin.ts.net}"
SSH_USER="${HOMELAB_USER:-root}"
TARGET="${SSH_USER}@${HOST}"
APP_NAME="glance"
# The chart checkout lives in derksen's home. Root can write it; $HOME would be /root.
APPS_HELM_DIR="${APPS_HELM_DIR:-/home/derksen/k3s/apps-helm}"
if [ -n "${SYNC_LOCAL_HOME:-}" ]; then
  APPS_HELM_DIR="${SYNC_LOCAL_HOME}/k3s/apps-helm"
fi

stamp_version() {
  local file="$1"
  local version="$2"
  sed -i -E "s/^(version:[[:space:]]+\"?)[^\"[:space:]]+/\1${version}/" "$file"
}

# Drop userinfo. Also repair "user:pass@/host/path", which has an empty host
# because an insteadOf rule rewrote http://host into http://user:pass@/host.
strip_userinfo() {
  local url="$1"
  local proto rest
  case "$url" in
    http://*|https://*)
      proto="${url%%://*}"
      rest="${url#*://}"
      rest="${rest#*@}"
      rest="${rest#/}"
      printf '%s://%s\n' "$proto" "$rest"
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

# Pull or push using the stored origin, not a rebuilt credential URL.
# git remote get-url applies insteadOf, and a rule that ends in "@/' makes curl
# see http:///10.43.239.83/... (no host). Pin the raw URL so that rule cannot run.
git_with_token() {
  local op="$1"
  local url basic
  url="$(git config --get remote.origin.url)"
  if [[ "$url" == http://* || "$url" == https://* ]]; then
    if [ -z "${token:-}" ]; then
      echo "APPS_HELM_GIT_TOKEN is required to sync apps-helm" >&2
      exit 1
    fi
    url="$(strip_userinfo "$url")"
    basic="$(printf 'oauth2:%s' "$token" | tr -d '\r\n' | base64 -w0)"
    if [ "$op" = pull ]; then
      git \
        -c "url.${url}.insteadOf=${url}" \
        -c "http.extraHeader=Authorization: Basic ${basic}" \
        pull --ff-only "$url" main >&2
    else
      git \
        -c "url.${url}.insteadOf=${url}" \
        -c "http.extraHeader=Authorization: Basic ${basic}" \
        push "$url" HEAD:main >&2
    fi
  elif [ "${local_mode:-0}" -eq 1 ]; then
    if [ "$op" = pull ]; then
      if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        git pull --ff-only >&2
      fi
    else
      git push >&2
    fi
  else
    echo "apps-helm origin must be http(s) so APPS_HELM_GIT_TOKEN can authenticate" >&2
    exit 1
  fi
}

exec_remote() {
  local script="$1"
  if [ -n "${SYNC_LOCAL_HOME:-}" ]; then
    HOME="$SYNC_LOCAL_HOME" bash -c "$script"
    return
  fi
  local encoded
  encoded="$(printf '%s' "$script" | base64 -w0)"
  tailscale ssh "$TARGET" "echo ${encoded} | base64 -d | bash"
}

copy_chart() {
  local src="$1"
  local dest="${APPS_HELM_DIR}/${APP_NAME}"
  if [ -n "${SYNC_LOCAL_HOME:-}" ]; then
    mkdir -p "$dest"
    tar -C "$src" -czf - . | tar -C "$dest" -xzf -
    return
  fi
  tar -C "$src" -czf - . | tailscale ssh "$TARGET" "mkdir -p \"${dest}\" && tar -C \"${dest}\" -xzf -"
}

if [ "${1:-}" = "--strip-url" ]; then
  strip_userinfo "$2"
  exit 0
fi

if [ "${1:-}" = "--stamp-test" ]; then
  tmp="$(mktemp)"
  printf 'version: 0.1.0\nappVersion: "0.8.4"\n' >"$tmp"
  stamp_version "$tmp" "0.1.1"
  grep -qx 'version: 0.1.1' "$tmp"
  printf 'version: "0.1.9"\n' >"$tmp"
  stamp_version "$tmp" "0.2.0"
  grep -qx 'version: "0.2.0"' "$tmp"
  rm -f "$tmp"
  exit 0
fi

if [ -z "${SYNC_LOCAL_HOME:-}" ] && [ -z "${APPS_HELM_GIT_TOKEN:-}" ]; then
  echo "APPS_HELM_GIT_TOKEN is required" >&2
  exit 1
fi

token_b64=""
if [ -n "${APPS_HELM_GIT_TOKEN:-}" ]; then
  token_b64="$(printf '%s' "$APPS_HELM_GIT_TOKEN" | base64 -w0)"
fi
local_mode=0
if [ -n "${SYNC_LOCAL_HOME:-}" ]; then
  local_mode=1
fi

read_script=$(cat <<EOF
set -euo pipefail
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0='*'
$(declare -f strip_userinfo)
$(declare -f git_with_token)
repo='${APPS_HELM_DIR}'
local_mode=${local_mode}
token="\$(printf '%s' '${token_b64}' | base64 -d | tr -d '\r\n')"
cd "\$repo"
git_with_token pull
if [ -f ${APP_NAME}/Chart.yaml ]; then
  awk '/^version:/{print \$2; exit}' ${APP_NAME}/Chart.yaml
else
  echo 0.1.0
fi
EOF
)

if [ -z "${SYNC_LOCAL_HOME:-}" ]; then
  echo "Checking Tailscale reachability for ${HOST}"
  tailscale ping --c 3 --timeout 10s "$HOST"
fi

current="$(exec_remote "$read_script")"
current="${current//$'\r'/}"
current="$(printf '%s\n' "$current" | tail -n 1 | tr -d '"')"

if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Could not read a chart version from apps-helm (got: ${current})" >&2
  exit 1
fi

next="$("${ROOT}/deploy/bump-version.sh" "$current")"
echo "Bumping chart version ${current} -> ${next}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cp -a "${CHART_SRC}/." "$workdir/"
stamp_version "${workdir}/Chart.yaml" "$next"
grep -q "^version: ${next}$" "${workdir}/Chart.yaml"

echo "Copying chart into ${APPS_HELM_DIR}/${APP_NAME}"
copy_chart "$workdir"

commit_script=$(cat <<EOF
set -euo pipefail
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0='*'
$(declare -f strip_userinfo)
$(declare -f git_with_token)
repo='${APPS_HELM_DIR}'
local_mode=${local_mode}
token="\$(printf '%s' '${token_b64}' | base64 -d | tr -d '\r\n')"
cd "\$repo"
branch="\$(git rev-parse --abbrev-ref HEAD)"
if [ "\$branch" != "main" ]; then
  echo "apps-helm is on \$branch, expected main" >&2
  exit 1
fi
git add -A -- ${APP_NAME}
if git diff --cached --quiet; then
  echo "No changes to commit"
  exit 0
fi
if git config user.email >/dev/null 2>&1; then
  git commit -m "${APP_NAME}:${next}"
else
  git -c user.name="glance-ci" -c user.email="glance-ci@localhost" commit -m "${APP_NAME}:${next}"
fi
git_with_token push
echo "Pushed ${APP_NAME}:${next}"
EOF
)

exec_remote "$commit_script"
