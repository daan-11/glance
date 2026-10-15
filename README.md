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

## Cursor usage

The Home page has a small **Cursor** card in the left column, under the calendar. Every 10 minutes Glance exchanges a seeded desktop refresh token for a short-lived access token, builds a `WorkosCursorSessionToken` cookie, and reads the usage meters. The account password is not stored. The refresh token and user id are not stored in git.

Cursor's desktop client refreshes with `POST https://api2.cursor.sh/oauth/token` (`grant_type=refresh_token`, public client id `KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB`, the seeded `refresh_token`). A successful body is an `access_token` with `shouldLogout: false` and does not include a new refresh token, so the same secret is reused. Glance does not write anything back to the Secret. If Cursor later invalidates that refresh token, the card says the session did not refresh until the secret is updated.

The cookie is `WorkosCursorSessionToken=<user id>%3A%3A<access token>`.

| Row | Source | Field |
| --- | --- | --- |
| Cursor Models | `GET https://cursor.com/api/usage-summary` | `individualUsage.plan.autoPercentUsed` |
| Other Models | same response | `individualUsage.plan.apiPercentUsed` |
| Shared reset | same response | `billingCycleEnd` |
| Grok Bot | `POST https://cursor.com/api/dashboard/get-sand-usage-status` | `usagePercent` |
| Weekly reset | same response | `nextResetTimestampUtc` |

One-time setup, on a machine that is already logged into the Cursor app:

1. Read the refresh token. Do not copy the account password.

   Linux:

   ```bash
   sqlite3 ~/.config/Cursor/User/globalStorage/state.vscdb \
     "SELECT value FROM ItemTable WHERE key = 'cursorAuth/refreshToken';"
   ```

   macOS uses `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`. Windows uses `%APPDATA%\Cursor\User\globalStorage\state.vscdb`.

2. Read the user id once. It is the `user_...` prefix of the browser `WorkosCursorSessionToken` cookie (the text before `::`). The same id is the last segment of the access token's JWT `sub` (`google-oauth2|user_...` → `user_...`). `cursorAuth/accessToken` is in the same database and is only needed for that one read.

3. Create a Secret in the Glance namespace:

   ```bash
   kubectl -n <namespace> create secret generic glance-cursor-session \
     --from-literal=refresh-token='<cursorAuth/refreshToken>' \
     --from-literal=user-id='user_...'
   ```

4. In `deploy/helm/glance/values.yaml`, set `cursor.sessionSecretName` to `glance-cursor-session`. `cursor.refreshTokenSecretKey` defaults to `refresh-token` and `cursor.userIdSecretKey` defaults to `user-id`. Deploy. The Deployment injects those keys as `CURSOR_REFRESH_TOKEN` and `CURSOR_USER_ID`.

Until that name is set, both variables are empty strings, Glance still starts, and the card says the session did not refresh. A `shouldLogout: true` response means the seeded refresh token is no longer valid; repeat steps 1 and 3 from a logged-in Cursor app. An older `glance-cursor-admin` secret is unused and can be deleted.
