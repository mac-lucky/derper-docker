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
ENV DERP_ADDR=:443
ENV DERP_STUN=true
ENV DERP_STUN_PORT=3478
ENV DERP_HTTP_PORT=80
ENV DERP_VERIFY_CLIENTS=false
ENV DERP_VERIFY_CLIENT_URL=""

COPY --from=builder --chown=1000:1000 /go/bin/derper /app/derper
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Let UID 1000 bind :443 and :80. Inert under no_new_privs or with the
# capability dropped, which is fine since those setups use high ports.
RUN apk --no-cache add libcap-setcap && \
    setcap cap_net_bind_service=+ep /app/derper && \
    apk --no-cache del libcap-setcap

USER 1000

EXPOSE 80 443 3478/udp

ENTRYPOINT ["/entrypoint.sh"]
