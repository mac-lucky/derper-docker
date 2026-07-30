# Derper

[![GitHub Actions Workflow Status](https://github.com/mac-lucky/derper-docker/actions/workflows/docker-image.yml/badge.svg)](https://github.com/mac-lucky/derper-docker/actions/workflows/docker-image.yml)
[![Platform](https://img.shields.io/badge/platform-amd64%20%7C%20arm64-blue)](https://github.com/mac-lucky/derper-docker/pkgs/container/derper)

# Setup

> required: set env `DERP_DOMAIN` to your domain

```bash
docker run -e DERP_DOMAIN=derper.your-domain.com \
  -p 80:80 -p 443:443 -p 3478:3478/udp \
  -v derper-certs:/app/certs -v derper-state:/app/state \
  ghcr.io/mac-lucky/derper
```

Mount `/app/certs` and `/app/state`, otherwise the LetsEncrypt certificate and
the DERP node key are lost every time the container is recreated, and repeated
certificate requests will hit LetsEncrypt's rate limits.

| env                    | required | description                                                                 | default value     |
| -------------------    | -------- | ----------------------------------------------------------------------      | ----------------- |
| DERP_DOMAIN            | true     | derper server hostname                                                      | your-hostname.com |
| DERP_CERT_DIR          | false    | directory to store LetsEncrypt certs(if addr's port is :443)                | /app/certs        |
| DERP_STATE_DIR         | false    | directory holding the DERP node key (`derper.key`)                          | /app/state        |
| DERP_CERT_MODE         | false    | mode for getting a cert. possible options: manual, letsencrypt              | letsencrypt       |
| DERP_ADDR              | false    | listening server address                                                    | :443              |
| DERP_STUN              | false    | also run a STUN server                                                      | true              |
| DERP_STUN_PORT         | false    | The UDP port on which to serve STUN.                                        | 3478              |
| DERP_HTTP_PORT         | false    | The port on which to serve HTTP. Set to -1 to disable                       | 80                |
| DERP_VERIFY_CLIENTS    | false    | verify clients to this DERP server through a local tailscaled instance      | false             |
| DERP_VERIFY_CLIENT_URL | false    | if non-empty, an admission controller URL for permitting client connections | ""                |

## Ports and cert mode

derper only serves TLS when `DERP_ADDR` is on port 443, or when
`DERP_CERT_MODE` is `manual`. Any other combination makes it fall back to plain
HTTP without requesting a certificate, so the container refuses to start on a
`letsencrypt` + non-443 configuration rather than coming up without TLS.

To serve on a high port instead - behind a load balancer, or where binding
privileged ports is not possible - use `manual` mode and supply the certificate
yourself as `<DERP_CERT_DIR>/<DERP_DOMAIN>.crt` and `.key`:

```bash
docker run -e DERP_DOMAIN=derper.your-domain.com \
  -e DERP_CERT_MODE=manual -e DERP_ADDR=:8443 -e DERP_HTTP_PORT=8080 \
  -p 443:8443 -p 80:8080 -p 3478:3478/udp \
  -v /path/to/certs:/app/certs:ro -v derper-state:/app/state \
  ghcr.io/mac-lucky/derper
```

The image runs as UID 1000. The binary carries `cap_net_bind_service`, so the
default ports 443 and 80 work without running as root.

# Usage

Fully DERP setup offical documentation: https://tailscale.com/kb/1118/custom-derp-servers/

## Client verification

In order to use `DERP_VERIFY_CLIENTS`, the container needs access to Tailscale's Local API, which can usually be accessed through `/var/run/tailscale/tailscaled.sock`. If you're running Tailscale bare-metal on Linux, adding this to the `docker run` command should be enough: `-v /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock`
