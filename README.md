# hawk

Deploys and monitors the apps on the mini PC (`andrewsserver`). Each app runs as systemd services behind Caddy, on the tailnet only, at `https://<app>.andrewminghanjiang.com`.

## What it does

- **Registry.** `apps/<app>.env` holds each app's port, services and health path.
- **Deploys.** The reusable `release.yml` workflow tags a release, then the `hawk` runner runs `hawk deploy <app>`. That builds into `/opt/<app>/releases/<version>`, runs `<app>-predeploy` if the app has it, switches `/opt/<app>/current`, restarts, and checks the health path.
- **Rollback.** `sudo hawk rollback <app> [release]`.
- **Status page.** Gatus checks every app each minute at `https://status.andrewminghanjiang.com`.
- **Alerts** are emails, sent through Resend (budgie's sender):
  - an app is down 3 checks in a row, or its cert expires in under 7 days (gatus);
  - any app service fails, including backups and predeploy (`OnFailure=hawk-notify@`);
  - the box stops sending heartbeats, or its disk is 90%+ full (healthchecks.io emails you itself).

## Install or update (mini PC)

```sh
git clone https://github.com/minghanminghan/hawk ~/hawk   # first time
cd ~/hawk && git pull && sudo ./install.sh
```

The first run makes `/etc/hawk/hawk.env` from `~/hawk/hawk.env` (git-ignored) if it exists, or asks for:

- `RESEND_API_KEY`, `EMAIL_FROM` (on a domain verified in Resend) and `EMAIL_TO`;
- `HC_PING_URL`: make a healthchecks.io check with a 5 min period and 10 min grace. It emails your account when pings stop.

## Add an app

1. In this repo, add `apps/<app>.env` with a free port. Merge, then `git pull && sudo ./install.sh` on the box.
2. In the app repo, add to `deploy/`:
   - `build.sh`: runs in the new release dir with `VERSION`, `APP` and `OPT` set. It installs and builds.
   - `<app>.service` and any other units. `@PORT@` and `@NODE_BIN@` are filled in. Read and write data only in `/var/lib/<app>` and `/var/backups/<app>`.
   - optional `<app>-predeploy.service`: a oneshot that backs up and migrates, run from `/opt/<app>/next`.
   - optional `hawk-setup.sh`: extra root setup, run by `hawk setup`.
   - The app must answer `GET <HEALTH>` with `{"version": "<VERSION>"}`.
3. Call the reusable workflow from the app's `.github/workflows/release.yml`:

   ```yaml
   jobs:
     test: ...
     hawk:
       needs: test
       uses: minghanminghan/hawk/.github/workflows/release.yml@main
       permissions:
         contents: write
       with:
         app: <app>
   ```

4. On the box: add a runner for the repo, then set up the app from a checkout:

   ```sh
   gh api -X POST repos/minghanminghan/<repo>/actions/runners/registration-token -q .token   # laptop
   sudo hawk runner https://github.com/minghanminghan/<repo> <token>
   sudo hawk setup <app> ~/<checkout>
   ```

5. Push to `main`. The release deploys itself.

GitHub shares one runner between repos only inside an org. Until the repos move to one, each repo needs its own `hawk runner` line. All of them use the `hawk` label.
