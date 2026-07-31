#!/usr/bin/env bash
# Runs an already-built image the way production runs it and fails if it
# misbehaves. Does not build anything itself -- the caller builds the image
# and passes its ref, either as $SMOKE_IMAGE (how the shared docker-cicd
# reusable invokes this) or as the first argument (for a local run):
#
#   docker build --load -t derper-smoke .
#   SMOKE_IMAGE=derper-smoke scripts/smoke-test.sh
#   scripts/smoke-test.sh derper-smoke
#
# The important flag is --security-opt no-new-privileges. Kubernetes sets the
# same bit via allowPrivilegeEscalation: false, and it is the difference between
# a plain `docker run` (which passes almost anything) and the hardened runtime
# this image actually ships into.
set -euo pipefail

IMAGE="${1:-${SMOKE_IMAGE:-derper-smoke}}"
HOST=derp.test
# Container name and host port are both unique per run. `docker rm -f` returns
# before the daemon has released either, so reusing them makes a run started
# right after a previous one die with "name is already in use" / "port is
# already allocated" -- which looks exactly like the image being broken.
CN="smoke-derp-$$"
HTTPS_PORT=
WORKDIR="$(mktemp -d)"
FAILED=0

cleanup() {
  docker rm -f "$CN" "$CN-guard" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

echo "smoke-testing $IMAGE"

# derper's manual cert mode looks for <certdir>/<hostname>.crt and .key, and
# verifies the cert against the hostname. Go dropped the Common Name fallback,
# so a CN-only cert is rejected -- the SAN is required.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$WORKDIR/$HOST.key" -out "$WORKDIR/$HOST.crt" \
  -subj "/CN=$HOST" -addext "subjectAltName=DNS:$HOST" 2>/dev/null
# The container reads these as UID 1000, which is not the user running this
# script. mktemp -d gives 0700, so the directory needs the traverse bit too --
# chmod'ing only the files leaves the container with "permission denied".
chmod 755 "$WORKDIR"
chmod 644 "$WORKDIR/$HOST".*

# --- 1. starts at all under no_new_privs -------------------------------------
# A binary carrying file capabilities (setcap) fails execve with EPERM here and
# the container dies with exit 126. That shipped once and took the relay down.
docker run -d --name "$CN" \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  --read-only \
  --tmpfs /app/state:uid=1000 \
  -p 127.0.0.1::8443 \
  -e DERP_DOMAIN="$HOST" \
  -e DERP_CERT_MODE=manual \
  -v "$WORKDIR:/app/certs:ro" \
  "$IMAGE" >/dev/null

for _ in $(seq 30); do
  docker logs "$CN" 2>&1 | grep -q 'serving on' && break
  sleep 1
done

if docker ps --filter "name=$CN" --filter status=running --format '{{.Names}}' | grep -q "$CN"; then
  pass "starts under no-new-privileges + cap-drop ALL + read-only rootfs"
else
  code="$(docker inspect -f '{{.State.ExitCode}}' "$CN" 2>/dev/null || echo '?')"
  fail "container did not stay up (exit $code) -- see logs below for the reason"
  if [ "$code" = "126" ]; then
    echo "  hint: exit 126 here means the binary carries file capabilities (setcap)."
    echo "        execve of such a binary returns EPERM under no_new_privs, so the"
    echo "        container cannot start under Kubernetes allowPrivilegeEscalation: false."
  fi
  echo "--- logs ---"; docker logs "$CN" 2>&1 | tail -20
  exit 1
fi

# --- 2. TLS is actually served ------------------------------------------------
# Not cosmetic: derper serves plain HTTP unless the port is 443 or certmode is
# manual, and it does so silently.
if docker logs "$CN" 2>&1 | grep -q 'serving on :8443 with TLS'; then
  pass "serving on :8443 with TLS"
else
  fail "no 'with TLS' in logs -- derper may have fallen back to plain HTTP"
  docker logs "$CN" 2>&1 | tail -10
fi

# --resolve so SNI is the cert hostname; against localhost derper answers
# "cert mismatch with hostname" and this would fail for the wrong reason.
HTTPS_PORT="$(docker port "$CN" 8443/tcp | head -1 | sed 's/.*://')"
code="$(curl -sk --max-time 20 --resolve "$HOST:$HTTPS_PORT:127.0.0.1" \
  -o /dev/null -w '%{http_code}' "https://$HOST:$HTTPS_PORT/" || echo 000)"
if [ "$code" = "200" ]; then
  pass "https GET / returned 200"
else
  fail "https GET / returned $code, expected 200"
fi

# --- 3. derper is PID 1 -------------------------------------------------------
# The entrypoint must exec, not leave a shell wrapping it, or exit codes and
# signals are the shell's rather than derper's.
if docker exec "$CN" ps 2>/dev/null | awk '$1 == "1"' | grep -q '/app/derper'; then
  pass "derper runs as PID 1"
else
  fail "PID 1 is not derper"
  docker exec "$CN" ps 2>&1 | head -5
fi

# --- 4. SIGTERM reaches it ----------------------------------------------------
start=$(date +%s)
docker stop "$CN" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -le 3 ]; then
  pass "SIGTERM handled, stopped in ${elapsed}s"
else
  fail "took ${elapsed}s to stop -- SIGTERM is not reaching derper (10s SIGKILL timeout)"
fi

# --- 5. the letsencrypt/port guard fires --------------------------------------
# letsencrypt on a non-443 port makes derper serve plain HTTP and never request
# a certificate, so the entrypoint must refuse to start instead.
docker run -d --name "$CN-guard" \
  -e DERP_DOMAIN="$HOST" -e DERP_CERT_MODE=letsencrypt -e DERP_ADDR=:8443 \
  "$IMAGE" >/dev/null
guard_code="$(docker wait "$CN-guard" 2>/dev/null || echo 999)"

# `docker logs` right after `docker wait` can come back before the container's
# stderr has been flushed, so retry rather than reading once. Without this the
# assertion intermittently misses a message that is plainly there.
guard_log=""
for _ in 1 2 3 4 5; do
  guard_log="$(docker logs "$CN-guard" 2>&1 || true)"
  [ -n "$guard_log" ] && break
  sleep 1
done

if [ "$guard_code" = "1" ] && printf '%s' "$guard_log" | grep -q 'needs DERP_ADDR on port 443'; then
  pass "guard rejects letsencrypt on a non-443 port"
else
  fail "guard did not fire as expected (exit $guard_code, wanted 1 + refusal message)"
  printf '%s\n' "$guard_log" | tail -5
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "all smoke tests passed"
else
  echo "smoke tests FAILED"
fi
exit "$FAILED"
