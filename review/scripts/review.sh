#!/usr/bin/env bash
set -euo pipefail

project="${INPUT_PROJECT:-}"
path="${INPUT_PATH:-.}"
base="${INPUT_BASE:-${PR_BASE_SHA:-}}"
auth_mode="${INPUT_AUTH_MODE:-token}"
token="${INPUT_TOKEN:-}"
unset INPUT_TOKEN

[[ -n "$project" ]] || { echo 'project is required' >&2; exit 2; }
[[ -d "$path" ]] || { echo 'path must be an existing directory' >&2; exit 2; }
case "$auth_mode" in
  token)
    [[ "$token" == adv_sa_* ]] || { echo 'token requires a Doomer service-account token' >&2; exit 2; }
    [[ -z "${INPUT_PROFILE:-}" ]] || { echo 'profile requires auth-mode: existing' >&2; exit 2; }
    ;;
  existing)
    [[ -z "$token" ]] || { echo 'token cannot be combined with auth-mode: existing' >&2; exit 2; }
    ;;
  *) echo 'auth-mode must be token or existing' >&2; exit 2 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Validate before authenticating or uploading anything.
python3 -B - "$script_dir" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from timeout import timeout_seconds
import os
timeout_seconds(os.environ.get('INPUT_TIMEOUT_MINUTES', ''))
PY

config_dir=''
cleanup() {
  if [[ -n "$config_dir" ]]; then rm -rf -- "$config_dir"; fi
}
trap cleanup EXIT
review_pid=''
cancel_review() {
  local code="$1"
  trap '' TERM INT
  if [[ -n "$review_pid" ]]; then
    kill -TERM "$review_pid" 2>/dev/null || true
    wait "$review_pid" 2>/dev/null || true
  fi
  exit "$code"
}
trap 'cancel_review 143' TERM
trap 'cancel_review 130' INT

cli=(doomer)
if [[ -n "${INPUT_API_URL:-}" ]]; then cli+=(--api-url "$INPUT_API_URL"); fi
if [[ "$auth_mode" == token ]]; then
  # Isolate both credentials and profile selection from the runner's own login.
  config_dir="$(mktemp -d "${RUNNER_TEMP:?RUNNER_TEMP is required}/doomer-review-config.XXXXXX")"
  chmod 700 "$config_dir"
  export DOOMER_CONFIG_DIR="$config_dir"
  cli+=(--profile review-action)
  printf '%s\n' "$token" | "${cli[@]}" login --token-stdin
elif [[ -n "${INPUT_PROFILE:-}" ]]; then
  cli+=(--profile "$INPUT_PROFILE")
fi
token=''

result_file="$(mktemp "${RUNNER_TEMP:?RUNNER_TEMP is required}/doomer-review.XXXXXX")"
args=(review --project "$project" --path "$path" --format json)
if [[ -n "$base" ]]; then args+=(--base "$base"); fi
set +e
python3 "$script_dir/timeout.py" "${cli[@]}" "${args[@]}" >"$result_file" &
review_pid=$!
wait "$review_pid"
exit_code=$?
review_pid=''
set -e
if [[ "$exit_code" != 0 ]]; then exit "$exit_code"; fi

python3 - "$result_file" "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}" <<'PY'
import json
import re
import sys
with open(sys.argv[1], encoding='utf-8') as stream:
    envelope = json.load(stream)
if envelope.get('schemaVersion') != 1 or envelope.get('command') != 'review':
    raise SystemExit('Unexpected Doomer review JSON envelope')
data = envelope.get('data')
if not isinstance(data, dict):
    raise SystemExit('Missing Doomer review submission data')
review_id, status = data.get('id'), data.get('status')
if not isinstance(review_id, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', review_id):
    raise SystemExit('Invalid Doomer review ID')
if status not in ('queued', 'running', 'completed'):
    raise SystemExit('Doomer did not accept the review in a successful state')
with open(sys.argv[2], 'a', encoding='utf-8') as stream:
    stream.write(f'review-id={review_id}\nstatus={status}\nresult-file={sys.argv[1]}\n')
print(f'Submitted Doomer review {review_id} (status: {status}).')
print('Submission succeeded; this step does not wait for hosted review results or post GitHub comments.')
PY
