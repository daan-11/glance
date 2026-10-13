# glance

Helm chart and home-lab deploy for [Glance](https://github.com/glanceapp/glance), following the Chronoflow apps-helm flow.

Glance is already running from the public image `glanceapp/glance`. This repo does not build an image. Argo CD keeps deploying the chart from the local git repo at `~/k3s/apps-helm/glance` on `home-lab`.

## Chart

`deploy/helm/glance/` is the chart that is currently applied on the cluster:

- ClusterIP Service on port 80, container port 8080
- ConfigMap mounted at `/app/config/glance.yml`
- `replicaCount: 1` (the Deployment requires it)

## Deploy

Pushes to `main`, and manual runs, sync the chart to the home-lab:

1. Join the tailnet with `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET` (`tag:ci`).
2. Flatten `deploy/helm/glance/*` into `~/k3s/apps-helm/glance/` (no nested `glance/glance`).
3. Bump `Chart.yaml` `version` with the Chronoflow carry rule (`0.1.0` → `0.1.1`, `0.1.9` → `0.2.0`).
4. Commit `glance:<version>` and push `main` in `~/k3s/apps-helm`.

`image.tag` stays `latest`. The bumped field is the chart version, because there is no image to import with `k3s ctr`.

Add these Actions secrets on this repository (the same ones Chronoflow uses):

- `TS_OAUTH_CLIENT_ID`
- `TS_OAUTH_SECRET`
- `APPS_HELM_GIT_TOKEN`

The workflow SSHes with Tailscale SSH as `root` to `home-lab.vulture-qilin.ts.net` and updates `/home/derksen/k3s/apps-helm`. `APPS_HELM_GIT_TOKEN` is sent as HTTP Basic auth (user `oauth2`) on the origin URL stored in that repo. The URL is not rebuilt, so an `insteadOf` rule cannot move the Gitea host into the path.
