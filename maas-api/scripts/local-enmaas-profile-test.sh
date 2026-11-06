#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
PG_IMAGE="${PG_IMAGE:-docker.io/library/postgres:16-alpine}"
PG_NAME="maas-api-local-pg-$$"
API_LOG="$(mktemp -t maas-api-local.XXXXXX.log)"
TMP_DIR="$(mktemp -d -t maas-api-local.XXXXXX)"
API_PID=""

cleanup() {
  if [[ -n "$API_PID" ]]; then
    kill "$API_PID" 2>/dev/null || true
    wait "$API_PID" 2>/dev/null || true
  fi
  "$CONTAINER_ENGINE" rm -f "$PG_NAME" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR" "$API_LOG"
}
trap cleanup EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  if [[ -f "$API_LOG" ]]; then
    echo "--- maas-api log ---" >&2
    tail -80 "$API_LOG" >&2 || true
  fi
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require "$CONTAINER_ENGINE"
require curl
require jq
require go
require python3

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

echo "==> starting disposable postgres ($PG_IMAGE)"
"$CONTAINER_ENGINE" run -d --rm --name "$PG_NAME" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=test \
  -e POSTGRES_DB=postgres \
  -p 127.0.0.1::5432 \
  "$PG_IMAGE" >/dev/null

PG_PORT="$("$CONTAINER_ENGINE" port "$PG_NAME" 5432/tcp | awk -F: 'NR == 1 {print $NF}')"
[[ -n "$PG_PORT" ]] || fail "could not determine postgres host port"

for _ in $(seq 1 60); do
  if "$CONTAINER_ENGINE" exec "$PG_NAME" pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
"$CONTAINER_ENGINE" exec "$PG_NAME" pg_isready -U postgres >/dev/null 2>&1 || fail "postgres did not become ready"

echo "==> building maas-api locally"
GOPROXY=off GOFLAGS=-mod=vendor go build -o "$TMP_DIR/maas-api" ./cmd

echo "==> starting maas-api in enmaas profile"
API_PORT="${API_PORT:-$(free_port)}"
METRICS_PORT="${METRICS_PORT:-$(free_port)}"
export MAAS_DEPLOYMENT_PROFILE=enmaas
export MAAS_SUBSCRIPTION_MODE=standalone
export DATABASE_URL="postgresql://postgres:test@127.0.0.1:${PG_PORT}/postgres?sslmode=disable"
export TENANT_NAME=models-as-a-service
export MAAS_ADMIN_USERS=admin
export METRICS_SECURE=false
export METRICS_PORT="$METRICS_PORT"
export ADDRESS="127.0.0.1:$API_PORT"
export KUBECONFIG=/nonexistent

"$TMP_DIR/maas-api" >"$API_LOG" 2>&1 &
API_PID=$!

BASE="http://127.0.0.1:$API_PORT"
METRICS_BASE="http://127.0.0.1:$METRICS_PORT"

for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "$BASE/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
curl -fsS --max-time 2 "$BASE/health" >/dev/null 2>&1 || fail "maas-api did not become healthy"

HEALTH="$(curl -fsS "$BASE/health")"
jq -e '.status == "healthy"' <<<"$HEALTH" >/dev/null || fail "unexpected health response: $HEALTH"

METRICS="$(curl -fsS "$METRICS_BASE/metrics")"
grep -q 'maas_api_' <<<"$METRICS" || fail "maas_api metrics not found"

HEADERS=(
  -H 'X-MaaS-Username: local-test-user'
  -H 'X-MaaS-Group: ["local-test-group"]'
  -H 'X-MaaS-Tenant: models-as-a-service'
)

echo "==> creating test key"
CREATE="$(curl -fsS -X POST "$BASE/v1/api-keys" \
  -H 'Content-Type: application/json' \
  "${HEADERS[@]}" \
  -d '{"name":"local-test-key"}')"
KEY="$(jq -r '.key // empty' <<<"$CREATE")"
KEY_ID="$(jq -r '.id // empty' <<<"$CREATE")"
[[ "$KEY" == sk-oai-* ]] || fail "created key has unexpected format"
[[ -n "$KEY_ID" ]] || fail "created key has no id"

echo "==> validating test key"
VALIDATE="$(curl -fsS -X POST "$BASE/internal/v1/api-keys/validate" \
  -H 'Content-Type: application/json' \
  -d "$(jq -cn --arg key "$KEY" '{key: $key}')")"
jq -e '.valid == true and .username == "local-test-user"' <<<"$VALIDATE" >/dev/null \
  || fail "created key did not validate: $VALIDATE"

echo "==> searching for test key"
SEARCH="$(curl -fsS -X POST "$BASE/v1/api-keys/search" \
  -H 'Content-Type: application/json' \
  "${HEADERS[@]}" \
  -d '{}')"
jq -e --arg id "$KEY_ID" '.data[]? | select(.id == $id)' <<<"$SEARCH" >/dev/null \
  || fail "created key missing from search results"

echo "==> reading and revoking test key"
curl -fsS "${HEADERS[@]}" "$BASE/v1/api-keys/$KEY_ID" | jq -e --arg id "$KEY_ID" '.id == $id' >/dev/null \
  || fail "get key returned unexpected data"
curl -fsS -X DELETE "${HEADERS[@]}" "$BASE/v1/api-keys/$KEY_ID" >/dev/null \
  || fail "revoke key failed"

REVOKED="$(curl -fsS -X POST "$BASE/internal/v1/api-keys/validate" \
  -H 'Content-Type: application/json' \
  -d "$(jq -cn --arg key "$KEY" '{key: $key}')")"
jq -e '.valid == false' <<<"$REVOKED" >/dev/null || fail "revoked key still validates"

echo "==> checking invalid key behavior"
INVALID="$(curl -fsS -X POST "$BASE/internal/v1/api-keys/validate" \
  -H 'Content-Type: application/json' \
  -d '{"key":"sk-oai-invalid_invalid"}')"
jq -e '.valid == false' <<<"$INVALID" >/dev/null || fail "invalid key unexpectedly validated"

echo "==> checking enmaas route pruning"
for path in /v1/models /v1/subscriptions /v1/tenants; do
  status="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE$path")"
  [[ "$status" == "404" ]] || fail "$path returned $status, expected 404"
done

echo "==> checking schema remains version 6 without deleted_at"
VERSION="$("$CONTAINER_ENGINE" exec "$PG_NAME" psql -U postgres -d postgres -Atc 'SELECT version FROM schema_migrations')"
[[ "$VERSION" == "6" ]] || fail "unexpected schema version: $VERSION"
DELETED_AT="$("$CONTAINER_ENGINE" exec "$PG_NAME" psql -U postgres -d postgres -Atc "SELECT count(*) FROM information_schema.columns WHERE table_name='api_keys' AND column_name='deleted_at'")"
[[ "$DELETED_AT" == "0" ]] || fail "deleted_at unexpectedly present"

echo "==> checking no Kubernetes/CRD startup path was used"
if grep -Eq 'NewClusterConfig|Starting informers|Informer caches synced' "$API_LOG"; then
  fail "Kubernetes/CRD startup path appeared in logs"
fi

echo "PASS: EnMaaS profile local contract test"
