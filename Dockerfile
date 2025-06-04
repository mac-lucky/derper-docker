FROM golang:alpine AS builder
WORKDIR /app

ARG DERP_VERSION=latest
RUN go install tailscale.com/cmd/derper@${DERP_VERSION}

FROM alpine:latest
WORKDIR /app

RUN apk --no-cache add ca-certificates && \
    mkdir /app/certs

ENV DERP_ADDR :80
ENV DERP_STUN true
ENV DERP_STUN_PORT 3478
ENV DERP_VERIFY_CLIENTS false
ENV DERP_VERIFY_CLIENT_URL ""

COPY --from=builder /go/bin/derper .

CMD /app/derper \
    --a=$DERP_ADDR \
    --stun=$DERP_STUN  \
    --stun-port=$DERP_STUN_PORT \
    --verify-clients=$DERP_VERIFY_CLIENTS \
    --verify-client-url=$DERP_VERIFY_CLIENT_URL

