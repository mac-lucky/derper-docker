FROM golang:1.27-alpine@sha256:4cb7ac979db5fcc41cae44b2227ba5ab8a51e8807f40d9ba4dee20a0ad960b5b AS builder
WORKDIR /app

ARG DERP_VERSION=v1.102.4
RUN go install tailscale.com/cmd/derper@${DERP_VERSION}

FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
WORKDIR /app

# apk upgrade first: the digest-pinned base can lag Alpine package fixes, and
# upgrading at build picks them up without waiting for a base-image rebuild.
RUN apk --no-cache upgrade && \
    apk --no-cache add ca-certificates && \
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
