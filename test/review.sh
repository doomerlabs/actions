#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/runner" "$tmp/source with spaces"
export REVIEW_TEST_LOG="$tmp/log"
cat > "$tmp/bin/doomer" <<'CLI'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['REVIEW_TEST_LOG'], 'a') as log:
    log.write(json.dumps({'args': args, 'config': os.environ.get('DOOMER_CONFIG_DIR'), 'input_token': os.environ.get('INPUT_TOKEN')}) + '\n')
if 'login' in args:
    assert sys.stdin.read().strip() == 'adv_sa_test-secret'
    pathlib.Path(os.environ['DOOMER_CONFIG_DIR'], 'credential').write_text('test')
    sys.exit(int(os.environ.get('FAIL_LOGIN', '0')))
assert 'review' in args
assert '--format' in args and args[args.index('--format') + 1] == 'json'
if os.environ.get('FAIL_REVIEW'):
    sys.exit(7)
print(os.environ.get('REVIEW_RESPONSE', '{"schemaVersion":1,"command":"review","data":{"id":"review-123","status":"queued"}}'))
CLI
chmod +x "$tmp/bin/doomer"
export PATH="$tmp/bin:$PATH" RUNNER_TEMP="$tmp/runner" GITHUB_OUTPUT="$tmp/outputs"
export INPUT_PROJECT='my-team' INPUT_PATH="$tmp/source with spaces" INPUT_TIMEOUT_MINUTES=1
export INPUT_AUTH_MODE=token INPUT_TOKEN=adv_sa_test-secret PR_BASE_SHA=abc123
bash -n "$root/review/scripts/review.sh"
grep -Fq 'default: 2026.10.17' "$root/review/action.yml"
grep -Fq 'id: review' "$root/review/action.yml"
for output in review-id status result-file; do
  grep -Fq "steps.review.outputs.$output" "$root/review/action.yml"
done
bash "$root/review/scripts/review.sh"
grep -Fxq 'review-id=review-123' "$GITHUB_OUTPUT"
grep -Fxq 'status=queued' "$GITHUB_OUTPUT"
python3 - "$REVIEW_TEST_LOG" "$INPUT_PATH" <<'PY'
import json, os, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert len(calls) == 2
assert all(c['input_token'] is None for c in calls)
a = calls[-1]['args']
assert a[a.index('--path') + 1] == sys.argv[2]
assert a[a.index('--base') + 1] == 'abc123'
assert a[a.index('--project') + 1] == 'my-team'
assert calls[0]['config'] == calls[1]['config']
assert not os.path.exists(calls[0]['config'])
PY
for failure in FAIL_LOGIN FAIL_REVIEW; do
  : > "$GITHUB_OUTPUT"
  if env "$failure=7" bash "$root/review/scripts/review.sh" >"$tmp/error" 2>&1; then
    echo "$failure was ignored" >&2; exit 1
  fi
  [[ ! -s "$GITHUB_OUTPUT" ]]
  [[ -z "$(find "$RUNNER_TEMP" -name 'doomer-review-config.*' -print)" ]]
done
unset INPUT_TOKEN
export INPUT_AUTH_MODE=existing INPUT_PROFILE=work INPUT_BASE=explicit-base INPUT_API_URL=https://example.test/api
: > "$REVIEW_TEST_LOG"
bash "$root/review/scripts/review.sh"
python3 - "$REVIEW_TEST_LOG" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert len(calls) == 1
assert calls[0]['args'][:4] == ['--api-url', 'https://example.test/api', '--profile', 'work']
assert calls[0]['args'][-2:] == ['--base', 'explicit-base']
PY
for response in \
  '{"schemaVersion":1,"command":"run","data":{"id":"r","status":"queued"}}' \
  '{"schemaVersion":1,"command":"review","data":{"id":"r","status":"failed"}}' \
  '{"schemaVersion":1,"command":"review","data":{"id":"r\ninjected=yes","status":"queued"}}'; do
  : > "$GITHUB_OUTPUT"
  if REVIEW_RESPONSE="$response" bash "$root/review/scripts/review.sh" >"$tmp/error" 2>&1; then
    echo 'invalid result was accepted' >&2; exit 1
  fi
  [[ ! -s "$GITHUB_OUTPUT" ]]
done
: > "$REVIEW_TEST_LOG"
if INPUT_TIMEOUT_MINUTES=NaN bash "$root/review/scripts/review.sh" >"$tmp/error" 2>&1; then exit 1; fi
[[ ! -s "$REVIEW_TEST_LOG" ]]
if INPUT_AUTH_MODE=oidc bash "$root/review/scripts/review.sh" >"$tmp/error" 2>&1; then exit 1; fi
[[ ! -s "$REVIEW_TEST_LOG" ]]
echo 'hosted review action tests passed'
