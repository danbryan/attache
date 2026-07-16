#!/bin/zsh
# INF-327: deterministic context management smoke gate.
#
# Exercises context safety, budget compliance, retrieval, memory, and recovery
# through the evaluation harness and targeted unit tests. No network or paid
# inference. Suitable for local development and release readiness.
#
# Usage: scripts/context-smoke.sh
# Exit nonzero on regression.

set -euo pipefail
cd "$(dirname "$0")/.."

TMP_PATHS=()
cleanup() {
  # `path` is a special zsh array tied to PATH. Using it as the loop variable
  # corrupts command lookup partway through cleanup.
  for artifact_path in "${TMP_PATHS[@]:-}"; do
    [ -n "$artifact_path" ] && rm -rf "$artifact_path"
  done
}
trap cleanup EXIT

TOTAL_XCTESTS=0

run_swift_tests() {
  local label="$1"
  local filter="$2"
  local minimum_count="$3"
  local log_file
  local summary
  local executed_count
  log_file="$(mktemp -t attache-context-smoke.XXXXXX)"
  TMP_PATHS+=("$log_file")

  if ! swift test --filter "$filter" 2>&1 | tee "$log_file"; then
    echo "$label: FAIL"
    exit 1
  fi

  summary="$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$log_file" | tail -1 || true)"
  if [ -z "$summary" ]; then
    echo "$label: FAIL (no XCTest execution summary found)"
    exit 1
  fi
  if ! printf '%s\n' "$summary" | grep -Eq 'with 0 failures'; then
    echo "$label: FAIL ($summary)"
    exit 1
  fi
  executed_count="$(printf '%s\n' "$summary" | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')"
  if [ "$executed_count" -lt "$minimum_count" ]; then
    echo "$label: FAIL (expected at least $minimum_count XCTest cases, executed $executed_count)"
    exit 1
  fi
  TOTAL_XCTESTS=$((TOTAL_XCTESTS + executed_count))
  echo "$label: PASS ($summary)"
}

echo "INF-327 Context Management Smoke Gate"
echo "====================================="
echo

echo "[1/8] Build..."
swift build
echo "Build: PASS"
echo

echo "[2/8] Context evaluation harness..."
run_swift_tests "Evaluation harness" "AttacheEvaluationHarnessTests" 13
echo

echo "[3/8] Authorization, snapshot, lifecycle, and fallback matrix..."
run_swift_tests \
  "Authorization matrix" \
  "AttacheRequestAuthorityTests|AttacheRequestSnapshotTests|SessionContextRuntimeTests|AppModelConversationContextTests|AppModelPersonalitySwitchTests|AttacheDirectChatRuntimeTests|ModelCallSafetyTests|ConversationFallbackChainTests" \
  45
echo

echo "[4/8] Budget, giant-content, cumulative-tool, and production-broker matrix..."
run_swift_tests \
  "Budget and broker matrix" \
  "AttacheContextBudgetTests|ContextCompilerTests|AttacheToolBudgetEnforcerTests|AttacheProductionRequestBrokerTests|AttacheContextGateTests" \
  30
echo

echo "[5/8] Memory, retrieval, receipts, and exhaustive-review matrix..."
run_swift_tests \
  "Context data services" \
  "AttacheMemory|AttacheSession|AttacheProgressive|AttacheProjectFile|AttacheHierarchical|AttacheExhaustive|AttacheRetrieval|AttacheDataEgress|AttacheCapability|AttacheTokenUsage|AttacheContextReceipt|ContextManagementUIState" \
  60
echo

echo "[6/8] Packaged production serialization probe..."
SIGN_APP=0 scripts/package-app.sh >/dev/null
PROBE_DIR="$(mktemp -d /tmp/attache-context-probe.XXXXXX)"
TMP_PATHS+=("$PROBE_DIR")
APP_BINARY="$PWD/dist/Attache.app/Contents/MacOS/Attache"
"$APP_BINARY" --context-production-probe "$PROBE_DIR"
PROBE_MANIFEST_COUNTS="$(python3 - "$PROBE_DIR/manifest.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
print(manifest["roleCount"], len(manifest["entries"]))
PY
)"
ROLE_COUNT="${PROBE_MANIFEST_COUNTS%% *}"
EXPECTED_PROBE_COUNT="${PROBE_MANIFEST_COUNTS##* }"
PROBE_COUNT="$(find "$PROBE_DIR" -type f ! -name manifest.json | wc -l | tr -d ' ')"
if [ "$PROBE_COUNT" -ne "$EXPECTED_PROBE_COUNT" ]; then
  echo "Packaged production probe: FAIL (manifest describes $EXPECTED_PROBE_COUNT artifacts, found $PROBE_COUNT)"
  exit 1
fi
python3 - "$PROBE_DIR/http/conversation.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["model"] = "deliberately-mutated-after-compilation"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
PY
if "$APP_BINARY" --verify-context-production-probe "$PROBE_DIR" >/dev/null 2>&1; then
  echo "Packaged production probe: FAIL (serialized-payload mutation was not detected)"
  exit 1
fi
echo "Packaged production probe: PASS ($PROBE_COUNT captured HTTP/safe-CLI payloads across $ROLE_COUNT roles; mutation detected)"
echo

echo "[7/8] Packaged context UI and accessibility gate..."
ATTACHE_UI_SMOKE_SKIP_BUILD_PACKAGE=1 scripts/context-ui-smoke.sh
echo

echo "[8/8] Link checker..."
scripts/check-doc-links.sh
echo

echo "====================================="
echo "ALL CONTEXT SMOKE GATES PASSED"
echo "$TOTAL_XCTESTS XCTest cases executed across the named context matrices."
echo
echo "This gate is part of release readiness."
echo "See docs/context-management.md for the full documentation."
