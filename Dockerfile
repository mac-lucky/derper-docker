FROM golang:1.26-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS builder
WORKDIR /app

ARG DERP_VERSION=v1.98.10
RUN go install tailscale.com/cmd/derper@${DERP_VERSION}

FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
WORKDIR /app

RUN apk --no-cache add ca-certificates && \
    adduser -D -u 1000 appuser && \
    mkdir /app/certs /app/state && \
    chown 1000:1000 /app/certs /app/state

ENV DERP_DOMAIN=your-hostname.com
ENV DERP_CERT_MODE=letsencrypt
ENV DERP_CERT_DIR=/app/certs
ENV DERP_STATE_DIR=/app/state
ENV DERP_ADDR=:8443
ENV DERP_STUN=true
ENV DERP_STUN_PORT=3478
ENV DERP_HTTP_PORT=8080
ENV DERP_VERIFY_CLIENTS=false
ENV DERP_VERIFY_CLIENT_URL=""

COPY --from=builder --chown=1000:1000 /go/bin/derper /app/derper
COPY --chmod=755 entrypoint.sh /entrypoint.sh

USER 1000

# Deliberately non-privileged. Do not setcap cap_net_bind_service on the binary
# to reclaim :443/:80 -- execve of a file-capability binary returns EPERM under
# no_new_privs, so the container cannot start at all under Kubernetes
# allowPrivilegeEscalation: false or docker --security-opt no-new-privileges.
EXPOSE 8080 8443 3478/udp

ENTRYPOINT ["/entrypoint.sh"]
