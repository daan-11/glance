#!/usr/bin/env bash
# Copy deploy/helm/glance into ~/k3s/apps-helm/glance on the home-lab (flattened),
# bump the chart version, and push main. Mirrors the Chronoflow apps-helm sync.
# Glance has no image build: k3s pulls glanceapp/glance itself.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_SRC="${ROOT}/deploy/helm/glance"
HOST="${HOMELAB_HOST:-home-lab.vulture-qilin.ts.net}"
SSH_USER="${HOMELAB_USER:-derksen}"
TARGET="${SSH_USER}@${HOST}"
APP_NAME="glance"

stamp_version() {
  local file="$1"
  local version="$2"
  sed -i -E "s/^(version:[[:space:]]+\"?)[^\"[:space:]]+/\1${version}/" "$file"
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
  if [ -n "${SYNC_LOCAL_HOME:-}" ]; then
    mkdir -p "${SYNC_LOCAL_HOME}/k3s/apps-helm/${APP_NAME}"
    tar -C "$src" -czf - . | tar -C "${SYNC_LOCAL_HOME}/k3s/apps-helm/${APP_NAME}" -xzf -
    return
  fi
  tar -C "$src" -czf - . | tailscale ssh "$TARGET" "mkdir -p \"\$HOME/k3s/apps-helm/${APP_NAME}\" && tar -C \"\$HOME/k3s/apps-helm/${APP_NAME}\" -xzf -"
}

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

read_script=$(cat <<'EOF'
set -euo pipefail
export GIT_TERMINAL_PROMPT=0
cd "$HOME/k3s/apps-helm"
if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  git pull --ff-only >&2
fi
if [ -f glance/Chart.yaml ]; then
  awk '/^version:/{print $2; exit}' glance/Chart.yaml
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

echo "Copying chart into ~/k3s/apps-helm/${APP_NAME}"
copy_chart "$workdir"

commit_script=$(cat <<EOF
set -euo pipefail
export GIT_TERMINAL_PROMPT=0
cd "\$HOME/k3s/apps-helm"
branch=\$(git rev-parse --abbrev-ref HEAD)
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
git push
echo "Pushed ${APP_NAME}:${next}"
EOF
)

exec_remote "$commit_script"
