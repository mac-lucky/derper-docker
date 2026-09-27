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
  docker rm -f "$CN" >/dev/null 2>&1 || true
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
# --home=blank is a container arg, asserted in step 2.
docker run -d --name "$CN" \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  --read-only \
  --tmpfs /app/state:uid=1000 \
  --health-start-interval=1s \
  -p 127.0.0.1::8443 \
  -e DERP_DOMAIN="$HOST" \
  -e DERP_CERT_MODE=manual \
  -v "$WORKDIR:/app/certs:ro" \
  "$IMAGE" --home=blank >/dev/null

# Logs are read into a variable before grepping, never piped into grep -q:
# grep -q exits on the first match, docker logs then dies of SIGPIPE, and
# pipefail turns a match into a failure whenever the timing lines up.
for _ in $(seq 30); do
  logs="$(docker logs "$CN" 2>&1 || true)"
  grep -q 'serving on' <<<"$logs" && break
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
if grep -q 'serving on :8443 with TLS' <<<"$logs"; then
  pass "serving on :8443 with TLS"
else
  fail "no 'with TLS' in logs -- derper may have fallen back to plain HTTP"
  tail -10 <<<"$logs"
fi

# --resolve so SNI is the cert hostname; against localhost derper answers
# "cert mismatch with hostname" and this would fail for the wrong reason.
HTTPS_PORT="$(docker port "$CN" 8443/tcp | head -1 | sed 's/.*://')"
code="$(curl -sk --max-time 20 --resolve "$HOST:$HTTPS_PORT:127.0.0.1" \
  -o "$WORKDIR/home.html" -w '%{http_code}' "https://$HOST:$HTTPS_PORT/" || echo 000)"
if [ "$code" = "200" ]; then
  pass "https GET / returned 200"
else
  fail "https GET / returned $code, expected 200"
fi

# The default home page says "DERP"; --home=blank serves an empty body. An
# empty body is the proof that container args reach derper.
if [ "$code" = "200" ] && [ ! -s "$WORKDIR/home.html" ]; then
  pass "container args reach derper (--home=blank served an empty page)"
else
  fail "GET / was not blank -- container args are not reaching derper"
  head -c 200 "$WORKDIR/home.html" 2>/dev/null; echo
fi

# --- 3. the image HEALTHCHECK passes ------------------------------------------
for _ in $(seq 20); do
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CN" 2>/dev/null || true)"
  [ "$health" = "healthy" ] && break
  sleep 1
done
if [ "$health" = "healthy" ]; then
  pass "healthcheck reports healthy"
else
  fail "healthcheck status is '${health:-none}', expected healthy"
  docker inspect -f '{{if .State.Health}}{{range .State.Health.Log}}{{.ExitCode}} {{.Output}}{{end}}{{end}}' "$CN" 2>/dev/null | tail -5
fi

# --- 4. derper is PID 1 -------------------------------------------------------
# The entrypoint must exec, not leave a shell wrapping it, or exit codes and
# signals are the shell's rather than derper's.
if docker exec "$CN" ps 2>/dev/null | awk '$1 == "1"' | grep -q '/app/derper'; then
  pass "derper runs as PID 1"
else
  fail "PID 1 is not derper"
  docker exec "$CN" ps 2>&1 | head -5
fi

# --- 5. SIGTERM reaches it ----------------------------------------------------
start=$(date +%s)
docker stop "$CN" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -le 3 ]; then
  pass "SIGTERM handled, stopped in ${elapsed}s"
else
  fail "took ${elapsed}s to stop -- SIGTERM is not reaching derper (10s SIGKILL timeout)"
fi

# --- 6. the version is stamped -----------------------------------------------
# Without the -X stamps in the Dockerfile this says "<version>-ERR-BuildInfo".
version="$(docker run --rm --entrypoint /app/derper "$IMAGE" --version 2>&1 || true)"
if [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+ && $version != *ERR* ]]; then
  pass "derper --version is stamped ($version)"
else
  fail "derper --version returned '$version', expected a clean x.y.z"
fi

# --- 7. the entrypoint guards fire --------------------------------------------
# letsencrypt or gcp on a non-443 port makes derper serve plain HTTP and never
# request a certificate, and an empty DERP_DOMAIN has nothing to get one for,
# so the entrypoint must refuse to start instead.
# Attached `docker run` returns only once the output has been read, unlike
# `docker logs` after `docker wait`, which could miss the refusal message.
#   expect_refusal <label> <expected message> <docker run args...>
expect_refusal() {
  local label="$1" want="$2" code=0 log
  shift 2
  log="$(docker run --rm "$@" "$IMAGE" 2>&1)" || code=$?
  if [ "$code" = 1 ] && grep -q "$want" <<<"$log"; then
    pass "guard rejects $label"
  else
    fail "guard did not reject $label (exit $code, wanted 1 + '$want')"
    tail -5 <<<"$log"
  fi
}

expect_refusal "letsencrypt on a non-443 port" 'letsencrypt needs DERP_ADDR on port 443' \
  -e DERP_DOMAIN="$HOST" -e DERP_CERT_MODE=letsencrypt -e DERP_ADDR=:8443
expect_refusal "gcp on a non-443 port" 'gcp needs DERP_ADDR on port 443' \
  -e DERP_DOMAIN="$HOST" -e DERP_CERT_MODE=gcp -e DERP_ADDR=:8443
expect_refusal "an empty DERP_DOMAIN" 'DERP_DOMAIN is not set' \
  -e DERP_CERT_MODE=manual

echo
if [ "$FAILED" -eq 0 ]; then
  echo "all smoke tests passed"
else
  echo "smoke tests FAILED"
fi
exit "$FAILED"
