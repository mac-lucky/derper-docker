#!/bin/sh
set -eu

# Without a hostname derper still starts, but letsencrypt mode then asks for a
# certificate nobody can validate and runs into LetsEncrypt's failed-validation
# rate limit, while manual mode has no certificate to load.
if [ -z "$DERP_DOMAIN" ]; then
    echo "derper: DERP_DOMAIN is not set." >&2
    echo "derper: set it to the hostname (or IP address) clients reach this server on; see the README." >&2
    exit 1
fi

# derper only serves TLS when the listen port is 443 or when certmode is
# manual (serveTLS := tsweb.IsProd443(*addr) || *certMode == "manual").
# Any other combination (letsencrypt or gcp on another port) silently falls
# back to plain HTTP and never requests a certificate, so refuse to start
# instead of pretending to work.
if [ "$DERP_CERT_MODE" != "manual" ]; then
    port=${DERP_ADDR##*:}
    if [ "$port" != "443" ] && [ "$port" != "https" ]; then
        echo "derper: DERP_CERT_MODE=$DERP_CERT_MODE needs DERP_ADDR on port 443 (got '$DERP_ADDR')." >&2
        echo "derper: set DERP_ADDR=:443, or use DERP_CERT_MODE=manual to serve TLS on another port." >&2
        exit 1
    fi
fi

# Container args are appended, so any other derper flag can be passed (e.g.
# --home=blank). Go's flag package keeps the last value, so an arg could also
# override the flags below; set those through their DERP_* env instead, since
# the checks above only see the env.
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
    --verify-client-url="${DERP_VERIFY_CLIENT_URL:-}" \
    "$@"
