#!/usr/bin/env bash
set -euo pipefail

export APP_API_KEY="${APP_API_KEY:-test-key}"

python -m py_compile \
  server/main.py \
  server/test_validation.py \
  server/test_http_contracts.py \
  server/test_config.py \
  server/test_storage.py \
  server/training_server/*.py

python -m pytest server
python scripts/validate_durable_runtime.py
