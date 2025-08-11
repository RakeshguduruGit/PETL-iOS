#!/usr/bin/env bash
set -eo pipefail

echo "🔒 Running Xcode build-phase guardrails..."

# Build Phase: Guardrails (fails build on violation)
if [ -x "scripts/guardrails.sh" ]; then
  ./scripts/guardrails.sh
else
  echo "❌ guardrails.sh missing - build will fail"
  exit 1
fi

echo "✅ Guardrails passed"
