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
