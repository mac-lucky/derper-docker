#!/bin/sh
set -eu

# derper only serves TLS when the listen port is 443 or when certmode is
# manual (serveTLS := tsweb.IsProd443(*addr) || *certMode == "manual").
# Any other combination silently falls back to plain HTTP and never requests
# a certificate, so refuse to start instead of pretending to work.
if [ "$DERP_CERT_MODE" = "letsencrypt" ]; then
    port=${DERP_ADDR##*:}
    if [ "$port" != "443" ] && [ "$port" != "https" ]; then
        echo "derper: DERP_CERT_MODE=letsencrypt needs DERP_ADDR on port 443 (got '$DERP_ADDR')." >&2
        echo "derper: set DERP_ADDR=:443, or use DERP_CERT_MODE=manual to serve TLS on another port." >&2
        exit 1
    fi
fi

exec /app/derper \
    -c "$DERP_STATE_DIR/derper.key" \
    --hostname="$DERP_DOMAIN" \
    --certmode="$DERP_CERT_MODE" \
    --certdir="$DERP_CERT_DIR" \
    -a "$DERP_ADDR" \
    --stun="$DERP_STUN" \
    --stun-port="$DERP_STUN_PORT" \
    --http-port="$DERP_HTTP_PORT" \
    --verify-clients="$DERP_VERIFY_CLIENTS" \
    --verify-client-url="${DERP_VERIFY_CLIENT_URL:-}"
