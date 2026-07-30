# Derper

[![GitHub Actions Workflow Status](https://github.com/mac-lucky/derper-docker/actions/workflows/docker-image.yml/badge.svg)](https://github.com/mac-lucky/derper-docker/actions/workflows/docker-image.yml)
[![Platform](https://img.shields.io/badge/platform-amd64%20%7C%20arm64-blue)](https://github.com/mac-lucky/derper-docker/pkgs/container/derper)

# Setup

> required: set env `DERP_DOMAIN` to your domain

```bash
docker run -e DERP_DOMAIN=derper.your-domain.com \
  -e DERP_ADDR=:443 -e DERP_HTTP_PORT=80 --user 0 \
  -p 80:80 -p 443:443 -p 3478:3478/udp \
  -v derper-certs:/app/certs -v derper-state:/app/state \
  ghcr.io/mac-lucky/derper
```

LetsEncrypt needs port 443 (see below), and the image runs as UID 1000, which
cannot bind it -- hence `--user 0` above. If you would rather not run as root,
use `manual` cert mode on the default high ports instead.

Mount `/app/certs` and `/app/state`, otherwise the LetsEncrypt certificate and
the DERP node key are lost every time the container is recreated, and repeated
certificate requests will hit LetsEncrypt's rate limits.

| env                    | required | description                                                                 | default value     |
| -------------------    | -------- | ----------------------------------------------------------------------      | ----------------- |
| DERP_DOMAIN            | true     | derper server hostname                                                      | your-hostname.com |
| DERP_CERT_DIR          | false    | directory to store LetsEncrypt certs(if addr's port is :443)                | /app/certs        |
| DERP_STATE_DIR         | false    | directory holding the DERP node key (`derper.key`)                          | /app/state        |
| DERP_CERT_MODE         | false    | mode for getting a cert. possible options: manual, letsencrypt              | letsencrypt       |
| DERP_ADDR              | false    | listening server address                                                    | :8443             |
| DERP_STUN              | false    | also run a STUN server                                                      | true              |
| DERP_STUN_PORT         | false    | The UDP port on which to serve STUN.                                        | 3478              |
| DERP_HTTP_PORT         | false    | The port on which to serve HTTP. Set to -1 to disable                       | 8080              |
| DERP_VERIFY_CLIENTS    | false    | verify clients to this DERP server through a local tailscaled instance      | false             |
| DERP_VERIFY_CLIENT_URL | false    | if non-empty, an admission controller URL for permitting client connections | ""                |

## Ports and cert mode

derper only serves TLS when `DERP_ADDR` is on port 443, or when
`DERP_CERT_MODE` is `manual`. Any other combination makes it fall back to plain
HTTP without requesting a certificate, so the container refuses to start on a
`letsencrypt` + non-443 configuration rather than coming up without TLS.

The defaults are the high ports 8443 and 8080, which UID 1000 can bind on its
own. That means `manual` mode is the out-of-the-box path: supply the
certificate yourself as `<DERP_CERT_DIR>/<DERP_DOMAIN>.crt` and `.key`, and map
the standard ports on the host side.

```bash
docker run -e DERP_DOMAIN=derper.your-domain.com -e DERP_CERT_MODE=manual \
  -p 443:8443 -p 80:8080 -p 3478:3478/udp \
  -v /path/to/certs:/app/certs:ro -v derper-state:/app/state \
  ghcr.io/mac-lucky/derper
```

For `letsencrypt` you need `DERP_ADDR=:443`, and binding it requires either
`--user 0` or an added `NET_BIND_SERVICE` capability. The binary deliberately
does not carry that capability via `setcap`: a file-capability binary fails to
`execve` with EPERM under `no_new_privs`, which would break the image under
Kubernetes `allowPrivilegeEscalation: false`.

# Usage

Fully DERP setup offical documentation: https://tailscale.com/kb/1118/custom-derp-servers/

## Client verification

In order to use `DERP_VERIFY_CLIENTS`, the container needs access to Tailscale's Local API, which can usually be accessed through `/var/run/tailscale/tailscaled.sock`. If you're running Tailscale bare-metal on Linux, adding this to the `docker run` command should be enough: `-v /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock`
