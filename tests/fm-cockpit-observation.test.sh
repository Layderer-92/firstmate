#!/usr/bin/env bash
# Behavioral coverage for the redacted, read-only Cockpit observation surface.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPORTER="$ROOT/bin/fm-cockpit-observation.sh"
WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-cockpit-observation)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CALL_LOG="$TMP_ROOT/external-calls.log"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
printf '# Seeded Firstmate home\n' > "$HOME_DIR/AGENTS.md"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF

for command_name in ssh gh herdr no-mistakes tmux; do
  cat > "$FAKEBIN/$command_name" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "$FM_TEST_EXTERNAL_CALL_LOG"
exit 91
SH
  chmod +x "$FAKEBIN/$command_name"
done

SUMMARY="$TMP_ROOT/private-summary.json"
cat > "$SUMMARY" <<EOF
{
  "schema": "fm-secondmate-home-summary.v1",
  "generated": "2026-09-04T20:00:00Z",
  "generated_epoch": 1788552000,
  "home": "/secret/home/CANARY_PATH",
  "valid": true,
  "reason": "CANARY_REASON",
  "invalidity": {"kind": null, "ids": ["CANARY_CHILD"]},
  "state": "active_child_work",
  "active_children": [{"id":"CANARY_CHILD","kind":"ship","state":"working","repo":"CANARY_REPO","source":"pane","doing":"CANARY_PROMPT"}],
  "decisions_open": [{"id":"CANARY_CHILD","key":"CANARY_KEY","verb":"needs-decision","summary":"CANARY_DECISION"}],
  "holds": [{"id":"CANARY_CHILD","reason":"CANARY_HOLD"}],
  "queued": [{"id":"CANARY_CHILD","title":"CANARY_TITLE"}],
  "landed": [{"id":"CANARY_CHILD","report_path":"/secret/report"}],
  "endpoints": [{"id":"CANARY_CHILD","endpoint":{"target":"CANARY_ENDPOINT"}}],
  "counts": {"active_children":1,"decisions_open":1,"holds":1,"queued":1,"landed":1,"endpoints":1},
  "omitted": [{"surface":"active_children","count":7}],
  "lineage": {"parent":"CANARY_PARENT"}
}
EOF

PUBLIC_JSON=$(FM_TEST_EXTERNAL_CALL_LOG="$CALL_LOG" PATH="$FAKEBIN:$PATH" \
  "$EXPORTER" --project-summary "$SUMMARY") \
  || fail "valid private summary was not projected"

printf '%s' "$PUBLIC_JSON" | jq -e '
  (keys == ["counts","data_class","invalidity","observed_at","observed_epoch","schema","state","valid"])
  and .schema == "fm-cockpit-observation.v1"
  and .data_class == "internal_non_sensitive"
  and .observed_at == "2026-09-04T20:00:00Z"
  and .observed_epoch == 1788552000
  and .state == "active_child_work"
  and .valid == true
  and .invalidity == null
  and (.counts | keys == ["active_children","decisions_open","endpoints","holds","landed","queued"])
  and .counts == {active_children:1,decisions_open:1,holds:1,queued:1,landed:1,endpoints:1}
' >/dev/null || fail "projection did not match the exact public schema"
if printf '%s' "$PUBLIC_JSON" | grep -F 'CANARY_' >/dev/null; then
  fail "private text, paths, identifiers, or lineage leaked into the public projection"
fi
[ ! -s "$CALL_LOG" ] || fail "projection executed an external command: $(cat "$CALL_LOG")"
pass "projection emits only the exact redacted schema"

printf '%s\n' "$PUBLIC_JSON" > "$HOME_DIR/state/cockpit-observation.json"
chmod 644 "$HOME_DIR/state/cockpit-observation.json"
READ_BACK=$(FM_HOME="$HOME_DIR" "$EXPORTER" --json) \
  || fail "public observation could not be read"
[ "$(printf '%s' "$READ_BACK" | jq -S .)" = "$(printf '%s' "$PUBLIC_JSON" | jq -S .)" ] \
  || fail "stdout mode changed the public document"
pass "stdout mode validates and returns the public document"

printf '%s' "$PUBLIC_JSON" | jq '.observed_epoch += 1' \
  > "$HOME_DIR/state/cockpit-observation.json"
if FM_HOME="$HOME_DIR" "$EXPORTER" --json >/dev/null 2>&1; then
  fail "mismatched observation timestamp and epoch were accepted"
fi
pass "timestamp and epoch must describe the same observation"

PRIOR_PUBLIC="$TMP_ROOT/prior-public.json"
printf '%s\n' "$PUBLIC_JSON" > "$PRIOR_PUBLIC"
printf '{"schema":"wrong"}\n' > "$HOME_DIR/state/cockpit-observation.json"
if FM_HOME="$HOME_DIR" "$EXPORTER" --json >/dev/null 2>&1; then
  fail "malformed public observation was accepted"
fi
dd if=/dev/zero of="$HOME_DIR/state/cockpit-observation.json" bs=70000 count=1 >/dev/null 2>&1
if FM_HOME="$HOME_DIR" "$EXPORTER" --json >/dev/null 2>&1; then
  fail "oversized public observation was accepted"
fi
rm -f "$HOME_DIR/state/cockpit-observation.json"
ln -s "$PRIOR_PUBLIC" "$HOME_DIR/state/cockpit-observation.json"
if FM_HOME="$HOME_DIR" "$EXPORTER" --json >/dev/null 2>&1; then
  fail "symlinked public observation was accepted"
fi
rm -f "$HOME_DIR/state/cockpit-observation.json"
if FM_HOME="$HOME_DIR" "$EXPORTER" --json >/dev/null 2>&1; then
  fail "missing public observation was accepted"
fi
pass "invalid, oversized, symlinked, and missing public files stop safely"

printf 'sentinel\n' > "$HOME_DIR/state/unrelated-state"
BEFORE_STATE=$(find "$HOME_DIR/state" -mindepth 1 -maxdepth 1 \
  ! -name 'home-summary.json' ! -name 'cockpit-observation.json' -print | sort)
BEFORE_SENTINEL=$(cksum "$HOME_DIR/state/unrelated-state")
PATH="$FAKEBIN:$PATH" FM_TEST_EXTERNAL_CALL_LOG="$CALL_LOG" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="2026-09-04T20:05:00Z" FM_SNAPSHOT_NOW_EPOCH=1788552300 \
  "$WRITER" || fail "integrated home-summary publication failed"
AFTER_STATE=$(find "$HOME_DIR/state" -mindepth 1 -maxdepth 1 \
  ! -name 'home-summary.json' ! -name 'cockpit-observation.json' -print | sort)
[ "$BEFORE_STATE" = "$AFTER_STATE" ] || fail "publisher left unrelated home-state changes"
[ "$BEFORE_SENTINEL" = "$(cksum "$HOME_DIR/state/unrelated-state")" ] \
  || fail "publisher changed unrelated home state"
[ "$(file_mode "$HOME_DIR/state/cockpit-observation.json")" = 644 ] \
  || fail "public observation mode is not 0644"
FM_HOME="$HOME_DIR" "$EXPORTER" --json | jq -e '
  .observed_at == "2026-09-04T20:05:00Z"
  and .observed_epoch == 1788552300
  and .state == "no_active_work"
  and .valid == true
  and .invalidity == null
  and .counts == {active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0}
' >/dev/null || fail "integrated publication was not deterministic"
[ ! -s "$CALL_LOG" ] || fail "integrated publication executed an external command: $(cat "$CALL_LOG")"
pass "home-summary refresh atomically publishes the redacted public observation"

PUBLIC_BEFORE_FAILURE=$(cksum "$HOME_DIR/state/cockpit-observation.json")
if PATH="$FAKEBIN:$PATH" FM_TEST_EXTERNAL_CALL_LOG="$CALL_LOG" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_COCKPIT_OBSERVATION_MAX_BYTES=1 \
  FM_SNAPSHOT_NOW="2026-09-04T20:06:00Z" FM_SNAPSHOT_NOW_EPOCH=1788552360 \
  "$WRITER" >/dev/null 2>&1; then
  fail "forced Cockpit projection failure was reported as success"
fi
jq -e '
  .generated == "2026-09-04T20:06:00Z"
  and .generated_epoch == 1788552360
' "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "Cockpit projection failure prevented the private summary publication"
[ "$PUBLIC_BEFORE_FAILURE" = "$(cksum "$HOME_DIR/state/cockpit-observation.json")" ] \
  || fail "Cockpit projection failure changed the prior public observation"
if find "$HOME_DIR/state" -maxdepth 1 \
    \( -name '.home-summary.json.*' -o -name '.cockpit-observation.json.*' \) \
    -print -quit | grep -q .; then
  fail "failed additive publication left a temporary file"
fi
pass "Cockpit projection failure preserves canonical and prior public state"

echo "all cockpit observation tests passed"
