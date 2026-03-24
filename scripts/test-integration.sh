#!/bin/bash
# Runs integration tests locally using .env file for credentials.
# Usage: ./scripts/test-integration.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    echo "Copy .env.example to .env and fill in your test credentials."
    exit 1
fi

# Export env vars from .env
set -a
source "$ENV_FILE"
set +a

echo "Running integration tests with:"
echo "  Email:  $DS3_TEST_EMAIL"
echo "  Bucket: $DS3_TEST_BUCKET"
echo ""

swift test --package-path "$PROJECT_DIR/DS3Lib"
