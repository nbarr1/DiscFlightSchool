#!/usr/bin/env bash
# Boots the real docker-compose stack (building the actual images) and
# exercises the live HTTP API end-to-end: upload, stats, export, model
# download, and enqueuing a training job through to the worker claiming it.
#
# Deliberately does NOT wait for a full `yolo detect train` run to finish —
# see README's "Current next steps" / docs/testing.md for why. This proves
# compose networking, schema bootstrap, the Redis queue, and worker startup
# all wire together; it does not validate model training itself.
set -euo pipefail
cd "$(dirname "$0")/.."

export APP_API_KEY="${APP_API_KEY:-ci-test-$(date +%s)}"
export POSTGRES_DB="${POSTGRES_DB:-discflight}"
export POSTGRES_USER="${POSTGRES_USER:-discflight}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-ci-test-pg-$(date +%s)}"
export MINIO_ROOT_USER="${MINIO_ROOT_USER:-ci-test-minio}"
export MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-ci-test-minio-$(date +%s)}"

API_URL="http://localhost:8000"

cleanup() {
  echo "--- docker compose logs (tail) ---"
  docker compose logs --tail=100 || true
  docker compose down -v
}
trap cleanup EXIT

docker compose --env-file server/.env.example up -d --build

echo "Waiting for training-api to become healthy..."
for i in $(seq 1 60); do
  if curl -sf "$API_URL/health" >/dev/null; then
    echo "training-api is up."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "training-api did not become healthy in time" >&2
    exit 1
  fi
  sleep 2
done

# A tiny valid JPEG, base64-encoded, so the upload endpoint's image
# validation (signature + decode) has something real to accept.
TMP_IMG="$(mktemp --suffix=.jpg)"
python3 -c "
import base64
data = base64.b64decode(
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkI'
    'CQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/wAALCAABAAEBAREA/8QAFAABAAAAAAAA'
    'AAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q=='
)
with open('$TMP_IMG', 'wb') as f:
    f.write(data)
"

upload_sample() {
  local sample_id="$1"
  curl -sf -X POST "$API_URL/api/training/upload" \
    -H "X-App-Key: $APP_API_KEY" \
    -F "sample_id=$sample_id" \
    -F "label=0 0.5 0.5 0.1 0.1" \
    -F "image_width=100" \
    -F "image_height=100" \
    -F "full_image=@$TMP_IMG;type=image/jpeg" \
    -F "crop_image=@$TMP_IMG;type=image/jpeg"
}

echo "Checking model download 404 (no model published yet)..."
status=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/api/model/download")
[ "$status" = "404" ] || { echo "expected 404, got $status" >&2; exit 1; }

echo "Uploading 3 samples and checking insufficient_data..."
for i in 1 2 3; do
  upload_sample "compose-smoke-$i" >/dev/null
done
start_response=$(curl -s -X POST "$API_URL/api/training/start" -H "X-App-Key: $APP_API_KEY")
echo "$start_response" | grep -q "insufficient_data" || {
  echo "expected insufficient_data, got: $start_response" >&2
  exit 1
}

echo "Uploading 7 more samples (10 total)..."
for i in 4 5 6 7 8 9 10; do
  upload_sample "compose-smoke-$i" >/dev/null
done

echo "Checking stats reflect 10 uploads..."
stats=$(curl -sf "$API_URL/api/training/stats")
echo "$stats" | grep -q '"total_samples":10' || {
  echo "expected total_samples:10 in stats, got: $stats" >&2
  exit 1
}

echo "Checking export produces a non-empty archive..."
curl -sf -X GET "$API_URL/api/training/export" -H "X-App-Key: $APP_API_KEY" -o /tmp/compose-export.zip
[ -s /tmp/compose-export.zip ] || { echo "export archive is empty" >&2; exit 1; }

echo "Starting training..."
start_response=$(curl -s -X POST "$API_URL/api/training/start" -H "X-App-Key: $APP_API_KEY")
echo "$start_response" | grep -q '"status":"started"' || {
  echo "expected status:started, got: $start_response" >&2
  exit 1
}

echo "Confirming a second start is rejected while one is active..."
status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL/api/training/start" -H "X-App-Key: $APP_API_KEY")
[ "$status" = "409" ] || { echo "expected 409 on concurrent start, got $status" >&2; exit 1; }

echo "Waiting for the worker to claim the queued job..."
for i in $(seq 1 30); do
  if docker compose logs training-worker 2>/dev/null | grep -q "worker.job.claimed"; then
    echo "Worker claimed the job."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "worker never claimed the queued job" >&2
    exit 1
  fi
  sleep 2
done

echo "Compose integration smoke test passed."
