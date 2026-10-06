# Freva services

This repository holds all definitions for Docker images to create services
that are needed to run Freva in production and development mode. Currently
those services are:

- MySQL
- MongoDB
- Apache Solr
- Redis
- Keycloak Open ID Connect service via OpenLDAP federation

### Building the containers images locally
Use `./local-build.sh` to build all service images locally.
Add the --check flag to run built-in healthchecks after the build.
The script supports both Docker and Podman, and will fail immediately
if any build or check fails:

```console
bash local-build.sh --check
```

## Build-time patches

Upstream fixes we need before they are released are kept as unified diffs in
`<SERVICE>/patches/`. Every `*.patch` / `*.diff` file in that directory is
applied to the installed Python packages while the image is built, by
`docker-scripts/apply-patches.sh`. The mechanism is generic: any service
directory may carry a `patches/` folder, and services without one are
unaffected.

### Writing a patch

Produce the diff against the package tree as it is laid out in the *install
location*, for python packages this is usually `site-packages`,
so that `patch -p1` finds the file:

```console
diff -u a/mlflow/store/tracking/sqlalchemy_workspace_store.py \
        b/mlflow/store/tracking/sqlalchemy_workspace_store.py > my-fix.patch
```

Two optional directives may be placed in the patch header. `patch` skips
everything before the first `---` line, so they can live in the patch file
itself:

```
# patch-root: PYTHON_SITE_PACKAGES   # default; or an absolute path
# patch-strip: 1                     # default; the -p level
```

A patch that is already applied is skipped. A patch that no longer applies
**fails the build** on purpose: after an MLflow bump that is the signal to
check whether the fix has landed upstream and the patch can be deleted.


## Integration tests

Besides the basic health check of `local-build.sh --check`, a service can
ship an integration test in `<service>/tests/run.sh`. CI runs it after the
image has been built, and its result is part of the required `CI result`
check. The tests start the image the way it runs in production, first the
version published today and then the new one on the same data, so they catch
broken upgrades as well as broken images.

| Service  | What is tested                                                                                     |
| -------- | -------------------------------------------------------------------------------------------------- |
| `mlflow` | PostgreSQL, Keycloak and S3 behind MLflow; schema migrations, auth, workspaces, artifacts. See [mlflow/README.md](mlflow/README.md#integration-test-ci) |
| `solr`   | cores, configs and index of the old image load in the new one; Freva's queries; schema strictness; blue/green rotation |

Run one locally after building the image, with podman or docker:

```console
bash local-build.sh --service=solr
bash solr/tests/run.sh ghcr.io/freva-org/freva-solr:latest
```

`KEEP=1` leaves the containers running for debugging, and `OLD_IMAGE=none`
skips the published image. Seeding pulls the published `:latest` image, which
replaces a local image with that tag; the test pins the new image by its ID
first, so it is not affected.

The container plumbing (engine detection, network, volumes, cleanup, logs on
failure) is shared in `tests/lib.sh`. Changing anything under `tests/`
rebuilds and tests all services.

### Solr

`solr/tests/run.sh` seeds a fresh data directory with the published image:
8 sample records in `files`, 4 in `latest`, and a leftover `files_crashed`
core like an interrupted rotation leaves behind. The new image then has to

- load both cores with the old index, and remove the leftover core on start;
- answer the queries Freva runs: case-insensitive facet values, synonyms
  (`months` finds `1mon`), facet counts, time ranges and bounding boxes;
- reject records with unknown fields (`autoCreateFields` stays off);
- accept new records;
- do a blue/green rotation: create a core from the `freva` configset, index
  into it, swap it in for `files` and unload the old one;
- keep the swapped core across a restart.

The test client uses only the Python standard library and runs in a
`python:3.12-slim` container.


## Automatic version updates

The `update-conda` workflow runs daily. For every service whose main package
has a newer version on conda-forge, it pushes a `bump-<pkg>-<old>-<new>`
branch and opens a pull request. The image build runs on that branch, and its
`CI result` check shows up on the PR.

### Auto-merge

Create an empty `<service>/.automerge` file to have version bumps of that
service merged without review:

```console
touch nginx/.automerge
```

For such a service the freva bot approves the PR and turns on auto-merge.
GitHub merges it as soon as `CI result` passes, and the push to `main` then
publishes the new image. If CI fails, the PR stays open. Services without the
file get a normal PR for review.

Who does what:

| Step                       | Identity              | Why                                                      |
| -------------------------- | --------------------- | -------------------------------------------------------- |
| push the branch            | freva bot (app)       | pushes with `GITHUB_TOKEN` don't start the image build   |
| open the PR                | `github-actions[bot]` | the author of a PR cannot approve it                     |
| approve, enable auto-merge | freva bot (app)       | the merge is done as the bot, so it triggers the publish |

The bot token is created from the `FREVA_BOT_CLIENT_ID` repository variable and
the `FREVA_BOT_PRIVATE_KEY` secret. The app needs **Contents** and **Pull
requests** read and write on this repository.

Repository settings this relies on:

- *Settings → General → Pull Requests*: **Allow auto-merge**, and
  **Automatically delete head branches**.
- *Settings → Actions → General → Workflow permissions*: **Allow GitHub
  Actions to create and approve pull requests**, so `github-actions[bot]` can
  open the PR.
- A branch protection rule or ruleset for `main` that requires
  - a pull request with at least **1 approval**, and
  - the status check **`CI result`**.

  Without a required check GitHub would merge right after the approval,
  before CI has run. Don't enable *Require branches to be up to date*: the
  bot does not rebase its branches, so PRs would wait for a manual update.

The image build only runs on pushes, not on `pull_request` events, so pull
requests from forks are not built automatically.


## Production Usage
> [!CAUTION]
> A manual setup of the service will most likely fail. You should set up this
> service via the [freva-deployment](https://freva-deployment.readthedocs.io/en/latest/)
> routine.

## Development Usage
Development environments should submodule this repository. See the
[freva-nextgen](https://github.com/freva-org/freva-nextgen) as an example.

## Keycloak
For development purpupose [Keycloak](https://www.keycloak.org) is pre configured
as an identity provider.
The keycloak configuration defines a *freva* realm. The realm defines a
``client_id=freva``. This freva realm has also
and openLDAP server configured. The openLDAP server configuration defines a
couple of dummy users:

- uid: johndoe, password: johndoe123, mail: john@example.com
- uid: janedoe, password: janedoe123, mail: jane@example.com
- uid: alicebrown, password: alicebrown123, mail: alice@example.com
- uid: bobsmith, password: bobsmith123, mail: bob@example.com
- uid: lisajones, password: lisajones123, mail: lisa@example.com
- uid: bobsmith, password: bobsmith123, mail: bob@existing.com

### Backup of data
If you need a simple backup functionality, you can add the `daily_backup.sh`
script in the same manner.

Setting up the volumes as outlined above will instruct the containers to
automatically creating new MariaDB tables (if not existing) and Solr cores
(if not existing).


If you added the `daily_backup.sh` files via a volume to the container you can
setup simple crontab to create backups on the *host* machine running
the container. A simple crontab example could like like this.

```
# m    h    dom   mon    dow      command
0      5    *     *      *        docker exec container-name bash -c /usr/local/bin/daily_backup
```
