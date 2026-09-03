#!/usr/bin/env bash
set -euo pipefail

status=${1:?status is required}
output=${2:?output path is required}
if [ "$status" -ne 0 ]; then
  exit 1
fi
if grep -q '^SKIP:' "$output"; then
  exit 2
fi
exit 0
