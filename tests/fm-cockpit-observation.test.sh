#!/usr/bin/env bash
# Behavioral coverage for the redacted, read-only Cockpit observation surface.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPORTER="$ROOT/bin/fm-cockpit-observation.sh"
WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
SCHEMA="$ROOT/contracts/fm-cockpit-observation-v1.schema.json"
CORPUS="$ROOT/tests/assets/fm-cockpit-observation-v1.conformance.json"
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

CONFORMANCE_CLASSES="valid timestamp_epoch_identity canonical_timestamp validity_coupling exact_keys enums counts source_clock_ahead"
if [ ! -f "$SCHEMA" ] || [ ! -f "$CORPUS" ]; then
  for vector_class in $CONFORMANCE_CLASSES; do
    printf 'not ok - conformance %s: canonical schema and corpus are required\n' \
      "$vector_class" >&2
  done
  exit 1
fi
command -v python3 >/dev/null 2>&1 || fail "python3 is required for schema conformance"

python3 - "$SCHEMA" "$CORPUS" "$EXPORTER" "$TMP_ROOT/conformance" <<'PY' \
  || fail "schema and semantic conformance corpus"
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys

schema_path, corpus_path, exporter_path, fixture_root = sys.argv[1:]
schema = json.loads(Path(schema_path).read_text(encoding="utf-8"))
corpus = json.loads(Path(corpus_path).read_text(encoding="utf-8"))
required_classes = {
    "valid",
    "timestamp_epoch_identity",
    "canonical_timestamp",
    "validity_coupling",
    "exact_keys",
    "enums",
    "counts",
    "source_clock_ahead",
}


def json_equal(left, right):
    return type(left) is type(right) and left == right


def resolve_ref(root, ref):
    if not ref.startswith("#/"):
        raise ValueError(f"unsupported non-local schema reference: {ref}")
    value = root
    for raw_part in ref[2:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        value = value[part]
    return value


def type_matches(name, value):
    if name == "object":
        return isinstance(value, dict)
    if name == "string":
        return isinstance(value, str)
    if name == "integer":
        return (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and float(value).is_integer()
        )
    if name == "boolean":
        return isinstance(value, bool)
    if name == "null":
        return value is None
    raise ValueError(f"unsupported schema type: {name}")


def validate(node_schema, value, root, path="$"):
    errors = []
    if "$ref" in node_schema:
        errors.extend(validate(resolve_ref(root, node_schema["$ref"]), value, root, path))
    expected_type = node_schema.get("type")
    if expected_type is not None and not type_matches(expected_type, value):
        return [f"{path}: expected {expected_type}"]
    if "const" in node_schema and not json_equal(value, node_schema["const"]):
        errors.append(f"{path}: const mismatch")
    if "enum" in node_schema and not any(json_equal(value, item) for item in node_schema["enum"]):
        errors.append(f"{path}: enum mismatch")
    if isinstance(value, str) and "pattern" in node_schema:
        if re.search(node_schema["pattern"], value) is None:
            errors.append(f"{path}: pattern mismatch")
    if (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and "minimum" in node_schema
    ):
        if value < node_schema["minimum"]:
            errors.append(f"{path}: below minimum")
    if isinstance(value, dict):
        for key in node_schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing {key}")
        properties = node_schema.get("properties", {})
        if node_schema.get("additionalProperties") is False:
            for key in value:
                if key not in properties:
                    errors.append(f"{path}: unknown {key}")
        for key, child_schema in properties.items():
            if key in value:
                errors.extend(validate(child_schema, value[key], root, f"{path}.{key}"))
    if "oneOf" in node_schema:
        matches = sum(not validate(branch, value, root, path) for branch in node_schema["oneOf"])
        if matches != 1:
            errors.append(f"{path}: expected exactly one oneOf match, got {matches}")
    return errors


failures = []
if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    failures.append("schema: Draft 2020-12 declaration is missing")
if corpus.get("schema") != "fm-cockpit-observation-conformance.v1":
    failures.append("corpus: wrong corpus schema")
if corpus.get("contract") != schema.get("properties", {}).get("schema", {}).get("const"):
    failures.append("corpus: contract does not match the canonical schema constant")
consumer_semantics = schema.get("x-firstmate-consumer-semantics", {})
structural_invalidity = consumer_semantics.get("structuralInvalidity", {})
future_timestamp = consumer_semantics.get("futureTimestamp", {})
if consumer_semantics.get("freshnessThresholdMilliseconds") != 10000:
    failures.append("schema: fixed freshness threshold must be 10000 milliseconds")
if structural_invalidity.get("verdict") != "source_invalid":
    failures.append("schema: structural invalidity verdict must be source_invalid")
if structural_invalidity.get("precedes") != "futureTimestamp":
    failures.append("schema: structural validation must precede future timestamp classification")
if "observation" not in structural_invalidity or structural_invalidity.get("observation") is not None:
    failures.append("schema: structural invalidity must carry no observation payload")
if future_timestamp.get("comparison") != "observed_epoch*1000 > consumer_now_ms":
    failures.append("schema: future timestamp comparison is missing")
if future_timestamp.get("toleranceMilliseconds") != 0:
    failures.append("schema: future timestamp tolerance must be zero milliseconds")
if future_timestamp.get("structuralValidationRequired") is not True:
    failures.append("schema: future timestamp classification must require structural validity")
if future_timestamp.get("verdict") != "source_clock_ahead":
    failures.append("schema: future timestamp verdict must be source_clock_ahead")
if "observation" not in future_timestamp or future_timestamp.get("observation") is not None:
    failures.append("schema: future timestamp verdict must carry no observation payload")
vectors = corpus.get("vectors")
if not isinstance(vectors, list):
    failures.append("corpus: vectors must be an array")
    vectors = []

seen_ids = set()
seen_classes = set()
counts = {}
source_clock_ahead_ids = set()
fixture_base = Path(fixture_root)


def contract_accepts(vector_id, document):
    home = fixture_base / vector_id
    state = home / "state"
    state.mkdir(parents=True, exist_ok=True)
    (state / "cockpit-observation.json").write_text(
        json.dumps(document, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    environment = os.environ.copy()
    environment["FM_HOME"] = str(home)
    result = subprocess.run(
        [exporter_path, "--json"],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    return result.returncode == 0, result.stderr.strip() or "accepted"


for vector in vectors:
    vector_id = vector.get("id")
    vector_class = vector.get("class")
    if not isinstance(vector_id, str) or not vector_id:
        failures.append("corpus: vector id must be a non-empty string")
        continue
    if vector_id in seen_ids:
        failures.append(f"corpus: duplicate vector id {vector_id}")
        continue
    seen_ids.add(vector_id)
    seen_classes.add(vector_class)
    counts[vector_class] = counts.get(vector_class, 0) + 1
    document = vector.get("document")
    schema_actual = not validate(schema, document, schema)
    if schema_actual is not vector.get("schema_valid"):
        failures.append(
            f"{vector_id}: schema expected {vector.get('schema_valid')} got {schema_actual}"
        )

    contract_actual, detail = contract_accepts(vector_id, document)
    if contract_actual is not vector.get("contract_valid"):
        failures.append(
            f"{vector_id}: contract expected {vector.get('contract_valid')} "
            f"got {contract_actual} ({detail})"
        )
    if vector_class == "source_clock_ahead":
        source_clock_ahead_ids.add(vector_id)
        consumer_now_ms = vector.get("consumer_now_ms")
        if not isinstance(consumer_now_ms, int):
            failures.append(f"{vector_id}: integer consumer_now_ms is required")
        elif document.get("observed_epoch", -1) * 1000 <= consumer_now_ms:
            failures.append(f"{vector_id}: vector timestamp is not in the future")
        expected_verdict = (
            future_timestamp.get("verdict")
            if schema_actual
            else structural_invalidity.get("verdict")
        )
        if vector.get("expected_source_verdict") != expected_verdict:
            failures.append(f"{vector_id}: expected verdict does not match schema ordering")
        if "expected_observation" not in vector or vector.get("expected_observation") is not None:
            failures.append(f"{vector_id}: expected observation payload must be null")

valid_document = next(
    (copy.deepcopy(vector["document"]) for vector in vectors if vector.get("id") == "valid-complete"),
    None,
)
if valid_document is None:
    failures.append("corpus: valid-complete vector is required for enum expansion")
else:
    for state_value in schema.get("properties", {}).get("state", {}).get("enum", []):
        document = copy.deepcopy(valid_document)
        document["state"] = state_value
        vector_id = f"allowed-state-{state_value}"
        if validate(schema, document, schema):
            failures.append(f"{vector_id}: canonical schema rejected its own state enum")
        contract_actual, detail = contract_accepts(vector_id, document)
        if not contract_actual:
            failures.append(f"{vector_id}: contract rejected allowed state ({detail})")
        counts["enums"] = counts.get("enums", 0) + 1
    for invalidity_value in schema.get("$defs", {}).get("invalidity", {}).get("enum", []):
        document = copy.deepcopy(valid_document)
        document["state"] = "unknown"
        document["valid"] = False
        document["invalidity"] = invalidity_value
        vector_id = f"allowed-invalidity-{invalidity_value}"
        if validate(schema, document, schema):
            failures.append(f"{vector_id}: canonical schema rejected its own invalidity enum")
        contract_actual, detail = contract_accepts(vector_id, document)
        if not contract_actual:
            failures.append(f"{vector_id}: contract rejected allowed invalidity ({detail})")
        counts["enums"] = counts.get("enums", 0) + 1

missing_classes = sorted(required_classes - seen_classes)
if missing_classes:
    failures.append(f"corpus: missing classes {', '.join(missing_classes)}")
required_source_clock_ahead_ids = {
    "future-structurally-valid",
    "future-structurally-invalid",
}
missing_source_clock_ahead_ids = sorted(
    required_source_clock_ahead_ids - source_clock_ahead_ids
)
if missing_source_clock_ahead_ids:
    failures.append(
        "corpus: missing source_clock_ahead vectors "
        + ", ".join(missing_source_clock_ahead_ids)
    )
unknown_classes = sorted(seen_classes - required_classes)
if unknown_classes:
    failures.append(f"corpus: unknown classes {', '.join(unknown_classes)}")
if failures:
    for failure in failures:
        print(f"not ok - {failure}", file=sys.stderr)
    raise SystemExit(1)
for vector_class in sorted(required_classes):
    count = counts[vector_class]
    noun = "vector" if count == 1 else "vectors"
    print(f"ok - conformance {vector_class}: {count} {noun}")
PY

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

MISSING_INVALIDITY_KIND_SUMMARY="$TMP_ROOT/missing-invalidity-kind-summary.json"
jq 'del(.invalidity.kind)' "$SUMMARY" > "$MISSING_INVALIDITY_KIND_SUMMARY"
if "$EXPORTER" --project-summary "$MISSING_INVALIDITY_KIND_SUMMARY" >/dev/null 2>&1; then
  fail "private summary without invalidity kind was projected"
fi
pass "projection rejects private summaries without invalidity kind"

printf '%s\n' "$PUBLIC_JSON" > "$HOME_DIR/state/cockpit-observation.json"
chmod 644 "$HOME_DIR/state/cockpit-observation.json"
READ_BACK=$(FM_HOME="$HOME_DIR" "$EXPORTER" --json) \
  || fail "public observation could not be read"
[ "$(printf '%s' "$READ_BACK" | jq -S .)" = "$(printf '%s' "$PUBLIC_JSON" | jq -S .)" ] \
  || fail "stdout mode changed the public document"
pass "stdout mode validates and returns the public document"

{
  printf '{"home":"/secret/home","doing":"private prompt text"}\n'
  printf '%s\n' "$PUBLIC_JSON"
} > "$HOME_DIR/state/cockpit-observation.json"
if FM_HOME="$HOME_DIR" "$EXPORTER" --json >/dev/null 2>&1; then
  fail "multiple public JSON values were accepted"
fi
MULTI_SUMMARY="$TMP_ROOT/multiple-private-summaries.json"
{
  printf '{"home":"/secret/home","doing":"private prompt text"}\n'
  cat "$SUMMARY"
} > "$MULTI_SUMMARY"
if "$EXPORTER" --project-summary "$MULTI_SUMMARY" >/dev/null 2>&1; then
  fail "multiple private JSON values were projected"
fi
pass "multiple JSON values are rejected before projection or read-back"

printf '%s' "$PUBLIC_JSON" | jq '.observed_epoch += 1' \
  > "$HOME_DIR/state/cockpit-observation.json"
if FM_HOME="$HOME_DIR" "$EXPORTER" --json >/dev/null 2>&1; then
  fail "mismatched observation timestamp and epoch were accepted"
fi
pass "timestamp and epoch must describe the same observation"

IMPOSSIBLE_SUMMARY="$TMP_ROOT/impossible-summary.json"
jq '.generated = "2026-02-30T00:00:00Z" | .generated_epoch = 1772409600' \
  "$SUMMARY" > "$IMPOSSIBLE_SUMMARY"
if "$EXPORTER" --project-summary "$IMPOSSIBLE_SUMMARY" >/dev/null 2>&1; then
  fail "non-canonical private timestamp was accepted despite matching normalized epoch"
fi
printf '%s' "$PUBLIC_JSON" | jq '
  .observed_at = "2026-02-30T00:00:00Z" | .observed_epoch = 1772409600
' > "$HOME_DIR/state/cockpit-observation.json"
if FM_HOME="$HOME_DIR" "$EXPORTER" --json >/dev/null 2>&1; then
  fail "non-canonical public timestamp was accepted despite matching normalized epoch"
fi
pass "impossible calendar dates are rejected on projection and read-back"

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
[ "$(file_mode "$HOME_DIR/state/cockpit-observation.json")" = 600 ] \
  || fail "public observation mode is not 0600"
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

PUBLIC_BEFORE_UNSAFE_TARGET="$TMP_ROOT/public-before-unsafe-target.json"
cp -p "$HOME_DIR/state/cockpit-observation.json" "$PUBLIC_BEFORE_UNSAFE_TARGET" \
  || fail "could not preserve the fixture public observation"
rm -f "$HOME_DIR/state/cockpit-observation.json"
mkdir "$HOME_DIR/state/cockpit-observation.json"
if PATH="$FAKEBIN:$PATH" FM_TEST_EXTERNAL_CALL_LOG="$CALL_LOG" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="2026-09-04T20:07:00Z" FM_SNAPSHOT_NOW_EPOCH=1788552420 \
  "$WRITER" >/dev/null 2>&1; then
  fail "directory at the fixed public export path was reported as success"
fi
if find "$HOME_DIR/state/cockpit-observation.json" -mindepth 1 -print -quit | grep -q .; then
  fail "publisher moved the staged observation into the unsafe directory"
fi
rmdir "$HOME_DIR/state/cockpit-observation.json" \
  || fail "unsafe fixture directory was not empty"
ln -s "$PUBLIC_BEFORE_UNSAFE_TARGET" "$HOME_DIR/state/cockpit-observation.json"
if PATH="$FAKEBIN:$PATH" FM_TEST_EXTERNAL_CALL_LOG="$CALL_LOG" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="2026-09-04T20:08:00Z" FM_SNAPSHOT_NOW_EPOCH=1788552480 \
  "$WRITER" >/dev/null 2>&1; then
  fail "symlink at the fixed public export path was reported as success"
fi
[ -L "$HOME_DIR/state/cockpit-observation.json" ] \
  || fail "publisher replaced the unsafe symlink target"
rm -f "$HOME_DIR/state/cockpit-observation.json"
cp -p "$PUBLIC_BEFORE_UNSAFE_TARGET" "$HOME_DIR/state/cockpit-observation.json" \
  || fail "could not restore the fixture public observation"
pass "writer rejects directory and symlink export targets without moving into them"

echo "all cockpit observation tests passed"
