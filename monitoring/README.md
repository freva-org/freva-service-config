# Monitoring

## `check_freva_service_version.py`

A Nagios/Icinga plugin that reports when a deployed Freva service container is
running an older version than the newest image published on
`ghcr.io/freva-org/freva-<service>`.

- **Deployed version:** the `org.opencontainers.image.version` label of the
  image the *running* container was started from. Pulling a newer `:latest`
  without restarting the service therefore still alerts.
- **Latest version:** the highest `X.Y.Z` tag of the image in the registry.
  This is the newest version that CI has actually built and published, so an
  alert always means there is something you can deploy.

| Deployed vs. latest                 | Default state |
| ----------------------------------- | ------------- |
| equal, newer, or patch level behind | OK            |
| minor version behind                | WARNING       |
| major version behind                | CRITICAL      |
| container missing or not running    | CRITICAL      |
| registry/podman error, no label     | UNKNOWN       |

Move the thresholds with `--warning-on` and `--critical-on`
(`patch`, `minor`, `major`, `never`).

The plugin only needs `python3` and `podman`, and works for every service in
this repository:

```console
check_freva_service_version.py --service mlflow --container mlflow
check_freva_service_version.py --service nginx  --container nginx
```

### Installation

Copy the plugin into the agent's plugin directory, e.g. on RHEL with a local
plugin path:

```console
install -o root -g root -m 0755 monitoring/check_freva_service_version.py \
    /usr/local/lib64/nagios/plugins/check_freva_service_version
```

It only needs `python3`, and outbound HTTPS to `ghcr.io`.

### Reading the deployed version

The quadlet units run as root, so their containers live in root's podman
storage, which the unprivileged agent user (`icinga` on RHEL, `nagios` on
Debian/Ubuntu) cannot query. There are two ways around that.

#### Status file (recommended, no sudo)

`mlflow/mlflow.container` saves the output of `podman ps` for its container to
`/run/freva-mlflow/status.json` once MLflow is healthy. The file holds state,
image and labels, no environment, so no secrets, and is world-readable.
systemd removes the directory when the service stops, so a missing file is
reported as CRITICAL: the service is not running.

```console
sudo -u icinga /usr/local/lib64/nagios/plugins/check_freva_service_version \
    --service mlflow --container mlflow \
    --status-file /run/freva-mlflow/status.json
```

Nothing on the host needs to change besides the plugin itself: no sudo rule,
no SELinux label. The file appears after the first restart with the updated
unit (`systemctl daemon-reload && systemctl restart mlflow`).

#### sudo

Without the status file, the plugin can run `podman ps` itself through sudo.
Allow the agent user that one command and nothing else:

```console
cat > /etc/sudoers.d/icinga-podman-ps <<'EOF'
icinga ALL=(root) NOPASSWD: /usr/bin/podman ps --all --format json --filter *
EOF
chmod 0440 /etc/sudoers.d/icinga-podman-ps
visudo -cf /etc/sudoers.d/icinga-podman-ps
```

and pass `--sudo` instead of `--status-file`. Use `podman ps`, never
`podman container inspect`: `inspect` prints the container environment, which
for these services contains database passwords, OIDC client secrets and S3
keys. With SELinux enforcing and `icinga2-selinux` installed, the confined
agent may also need the plugin labelled `nagios_unconfined_plugin_exec_t`
before it may use sudo.

### Icinga 2 configuration

`PluginDir` points to the distribution's plugin directory, so use the full
path when the plugin lives elsewhere:

```text
object CheckCommand "freva_service_version" {
  command = [ "/usr/local/lib64/nagios/plugins/check_freva_service_version" ]

  arguments = {
    "--service"     = "$freva_service$"
    "--container"   = "$freva_container$"
    "--status-file" = "$freva_status_file$"
    "--warning-on"  = "$freva_warning_on$"
    "--critical-on" = "$freva_critical_on$"
  }
}

apply Service "mlflow-version" {
  check_command = "freva_service_version"
  command_endpoint = host.name

  vars.freva_service = "mlflow"
  vars.freva_container = "mlflow"
  vars.freva_status_file = "/run/freva-mlflow/status.json"

  // Upstream releases are not urgent, there is no need to poll often.
  check_interval = 6h
  retry_interval = 30m

  assign where host.vars.freva_services && "mlflow" in host.vars.freva_services
}
```

Releases arrive at most a few times a month, so a check interval of a few
hours is plenty and keeps the anonymous registry requests low.

### Zabbix

The same plugin works as a Zabbix agent user parameter, e.g. in
`/etc/zabbix/zabbix_agent2.d/freva.conf`:

```text
UserParameter=freva.version[*],/usr/local/lib64/nagios/plugins/check_freva_service_version --service $1 --container $1 --status-file /run/freva-$1/status.json; echo " exit=$?"
```

The item `freva.version[mlflow]` returns the plugin's status line, ending in
`exit=0` (OK), `exit=1` (WARNING) or `exit=2` (CRITICAL). Trigger on it, for
example `find(/host/freva.version[mlflow],,"regexp","exit=[12]")=1`.
