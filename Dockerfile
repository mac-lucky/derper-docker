FROM golang:alpine AS builder
WORKDIR /app

ARG DERP_VERSION=latest
RUN go install tailscale.com/cmd/derper@${DERP_VERSION}

FROM alpine:latest
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
