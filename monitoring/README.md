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

```console
install -m 0755 monitoring/check_freva_service_version.py \
    /usr/lib/nagios/plugins/check_freva_service_version
```

The quadlet units run as root, so the containers live in root's podman
storage. If the Icinga agent runs as an unprivileged user (`nagios` on
Debian/Ubuntu, `icinga` on RHEL), allow it to list containers and nothing
else:

```console
cat > /etc/sudoers.d/icinga-podman-ps <<'EOF'
nagios ALL=(root) NOPASSWD: /usr/bin/podman ps --all --format json --filter *
EOF
chmod 0440 /etc/sudoers.d/icinga-podman-ps
visudo -cf /etc/sudoers.d/icinga-podman-ps
```

The plugin deliberately uses `podman ps` and not `podman container inspect`:
`inspect` prints the container environment, which for these services contains
database passwords, OIDC client secrets and S3 keys. Do not widen the sudo rule
to `inspect`.

Then pass `--sudo` to the plugin. Test it as the agent user:

```console
sudo -u nagios /usr/lib/nagios/plugins/check_freva_service_version \
    --service mlflow --container mlflow --sudo
```

The host needs outbound HTTPS to `ghcr.io`.

### Icinga 2 configuration

```text
object CheckCommand "freva_service_version" {
  command = [ PluginDir + "/check_freva_service_version" ]

  arguments = {
    "--service"     = "$freva_service$"
    "--container"   = "$freva_container$"
    "--warning-on"  = "$freva_warning_on$"
    "--critical-on" = "$freva_critical_on$"
    "--sudo" = {
      set_if = "$freva_sudo$"
    }
  }

  vars.freva_sudo = true
}

apply Service "mlflow-version" {
  check_command = "freva_service_version"
  command_endpoint = host.name

  vars.freva_service = "mlflow"
  vars.freva_container = "mlflow"

  // Upstream releases are not urgent, there is no need to poll often.
  check_interval = 6h
  retry_interval = 30m

  assign where host.vars.freva_services && "mlflow" in host.vars.freva_services
}
```

Releases arrive at most a few times a month, so a check interval of a few
hours is plenty and keeps the anonymous registry requests low.
