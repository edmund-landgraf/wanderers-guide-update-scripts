#!/usr/bin/env bash
# Shared helpers for update-wg-content.sh and update-wg-non-content.sh
set -euo pipefail

amba_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$here/../.." && pwd
}

log_dir() {
  if [[ -n "${WG_UPDATE_LOG_DIR:-}" ]]; then
    printf '%s\n' "$WG_UPDATE_LOG_DIR"
  else
    printf '%s\n' "$(amba_root)/logs/wg-update"
  fi
}

init_log_dir() {
  local d
  d="$(log_dir)"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

history_path() {
  printf '%s\n' "$(init_log_dir)/history.jsonl"
}

debug_log() {
  local file="$1"
  shift
  local line
  line="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  printf '%s\n' "$line" | tee -a "$file"
}

debug_log_file() {
  local file="$1"
  shift
  local line
  line="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  printf '%s\n' "$line" >>"$file"
}

git_c() {
  local src="$1"
  shift
  git -C "$src" -c "safe.directory=$src" "$@"
}

assert_git_src() {
  local src="$1"
  [[ -d "$src" ]] || { echo "WG source not found: $src" >&2; return 1; }
  [[ -d "$src/.git" ]] || {
    echo "Not a git checkout (no .git): $src. Clone wanderers-guide or restore .git in _wg-src." >&2
    return 1
  }
  git_c "$src" remote get-url origin >/dev/null
}

# Paths that still have @@ hunks after --ignore-cr-at-eol.
# git diff --name-only still lists CRLF-only files; do not use it.
hunk_paths_from_diff() {
  python3 - <<'PY'
import sys
current = None
has_hunk = False
paths = []
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if line.startswith("diff --git "):
        if current and has_hunk:
            paths.append(current)
        parts = line.split(" b/", 1)
        current = parts[1] if len(parts) == 2 else None
        has_hunk = False
    elif line.startswith("@@"):
        has_hunk = True
if current and has_hunk:
    paths.append(current)
print("\n".join(paths))
PY
}

repo_snapshot() {
  local src="$1" debug="$2"
  debug_log "$debug" "===== REPO SNAPSHOT ====="
  debug_log "$debug" "cwd=$(pwd) user=$(id -un) host=$(hostname)"
  debug_log "$debug" "HEAD=$(git_c "$src" rev-parse HEAD) branch=$(git_c "$src" rev-parse --abbrev-ref HEAD) origin/main=$(git_c "$src" rev-parse origin/main 2>/dev/null || true)"
  debug_log "$debug" "last commit:"$'\n'"$(git_c "$src" log -1 --format='%H%n%cI%n%s')"
  debug_log "$debug" "remotes:"$'\n'"$(git_c "$src" remote -v)"
  local st
  st="$(git_c "$src" status --porcelain=v1 -uall || true)"
  local n
  n="$(printf '%s\n' "$st" | grep -c . || true)"
  debug_log "$debug" "git status --porcelain lines=$n"
  debug_log_file "$debug" "git status --porcelain (full):"$'\n'"$st"
  debug_log_file "$debug" "git status (human):"$'\n'"$(git_c "$src" status || true)"
  debug_log "$debug" "===== END REPO SNAPSHOT ====="
}

restore_crlf_files() {
  local src="$1" debug="$2"
  shift 2
  local paths=("$@")
  [[ ${#paths[@]} -eq 0 ]] && return 0
  debug_log_file "$debug" "restoring ${#paths[@]} CRLF-only files so merge can proceed"
  local i=0
  while [[ $i -lt ${#paths[@]} ]]; do
    local chunk=("${paths[@]:$i:80}")
    git_c "$src" restore --worktree --source=HEAD -- "${chunk[@]}" >/dev/null 2>&1 || true
    i=$((i + 80))
  done
}

# Prints real dirty porcelain lines (not .env, not CR-only). Restores CR-only files.
worktree_real_dirty() {
  local src="$1" debug="$2"
  local porcelain unstaged staged real_list
  porcelain="$(git_c "$src" status --porcelain || true)"
  unstaged="$(git_c "$src" diff --ignore-cr-at-eol || true)"
  staged="$(git_c "$src" diff --cached --ignore-cr-at-eol || true)"
  real_list="$( { printf '%s\n' "$unstaged"; printf '%s\n' "$staged"; } | hunk_paths_from_diff )"
  local n_porc n_real
  n_porc="$(printf '%s\n' "$porcelain" | grep -c . || true)"
  n_real="$(printf '%s\n' "$real_list" | grep -c . || true)"
  debug_log_file "$debug" "dirty-check porcelain lines=$n_porc real-hunks=$n_real"
  debug_log_file "$debug" "dirty-check porcelain:"$'\n'"$porcelain"

  local dirty=() crlf=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local path="${line:3}"
    path="${path%\"}"
    path="${path#\"}"
    path="${path#"${path%%[![:space:]]*}"}"
    case "$path" in
      .env|.env.*|docker-compose.override.yml) continue ;;
    esac
    local code="${line:0:2}"
    if [[ "$code" == *"?"* ]] || printf '%s\n' "$real_list" | grep -Fxq "$path"; then
      dirty+=("$line")
      continue
    fi
    crlf+=("$path")
  done <<<"$porcelain"

  debug_log_file "$debug" "dirty-check summary: real=${#dirty[@]} crlfOnly=${#crlf[@]}"
  if [[ ${#crlf[@]} -gt 0 && ${#dirty[@]} -eq 0 ]]; then
    restore_crlf_files "$src" "$debug" "${crlf[@]}"
  fi
  if [[ ${#dirty[@]} -gt 0 ]]; then
    printf '%s\n' "${dirty[@]}"
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' <<<"${1:-}"
}

last_successful_history() {
  local kind="$1"
  local path host
  path="$(history_path)"
  [[ -f "$path" ]] || return 0
  host="$(hostname)"
  python3 - "$path" "$kind" "$host" <<'PY'
import json, sys
path, kind, host = sys.argv[1], sys.argv[2], sys.argv[3]
last = None
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("script") == kind and row.get("result") == "applied" and row.get("host") == host:
                last = row
except FileNotFoundError:
    pass
if last:
    print(json.dumps(last))
PY
}

compose_created() {
  local src="$1"
  local id
  id="$(docker compose -f "$src/docker-compose.yml" --project-directory "$src" ps -q frontend 2>/dev/null | head -n1 || true)"
  if [[ -z "$id" ]]; then
    id="$(docker compose -f "$src/docker-compose.yml" --project-directory "$src" ps -q 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$id" ]] || return 0
  docker inspect -f '{{.Created}}' "$id" 2>/dev/null || true
}

head_sha() {
  git_c "$1" rev-parse HEAD
}

head_date() {
  git_c "$1" log -1 --format=%cI
}

resolve_baseline() {
  local src="$1" kind="$2" since_override="${3:-}"
  if [[ -n "$since_override" ]]; then
    if [[ "$since_override" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
      printf 'flag\t\t%s\n' "$since_override"
    else
      printf 'flag\t%s\t\n' "$since_override"
    fi
    return 0
  fi

  local hist
  hist="$(last_successful_history "$kind" || true)"
  if [[ -n "$hist" ]]; then
    python3 -c 'import json,sys; r=json.loads(sys.argv[1]); print("log\t%s\t%s" % (r.get("ts") or "", r.get("newSha") or ""))' "$hist"
    return 0
  fi

  local created
  created="$(compose_created "$src" || true)"
  if [[ -n "$created" ]]; then
    printf 'compose\t%s\t\n' "$created"
    return 0
  fi

  printf 'head\t%s\t%s\n' "$(head_date "$src")" "$(head_sha "$src")"
}

commits_in_window() {
  local src="$1" kind="$2" base_sha="$3" base_since="$4"
  local args=(log --format='%H%x09%cI%x09%s')
  if [[ -n "$base_sha" ]]; then
    args+=("${base_sha}..origin/main")
  else
    args+=(--since="$base_since" origin/main)
  fi
  if [[ "$kind" == "content" ]]; then
    args+=(-- data/schema.sql data/data.sql)
  else
    args+=(-- . ':(exclude)data/schema.sql' ':(exclude)data/data.sql')
  fi
  git_c "$src" "${args[@]}"
}

append_history() {
  local json="$1"
  printf '%s\n' "$json" >>"$(history_path)"
}

step_log() {
  local file="$1" n="$2" total="$3" name="$4" status="$5"
  shift 5
  debug_log "$file" "STEP $n/$total $status $name $*"
}

git_rollback() {
  local src="$1" old_sha="$2" debug="$3"
  local env_file="$src/.env" env_bak=""
  if [[ -f "$env_file" ]]; then
    env_bak="$(mktemp)"
    cp "$env_file" "$env_bak"
  fi
  debug_log "$debug" "ROLLBACK git reset --hard $old_sha"
  local out
  if ! out="$(git_c "$src" reset --hard "$old_sha" 2>&1)"; then
    debug_log "$debug" "$out"
    [[ -n "$env_bak" ]] && rm -f "$env_bak"
    return 1
  fi
  debug_log "$debug" "$out"
  if [[ -n "$env_bak" ]]; then
    cp "$env_bak" "$env_file"
    rm -f "$env_bak"
  fi
  return 0
}

frontend_image() {
  local src="$1"
  local id
  id="$(docker compose -f "$src/docker-compose.yml" --project-directory "$src" ps -q frontend 2>/dev/null | head -n1 || true)"
  [[ -n "$id" ]] || return 0
  docker inspect -f '{{.Image}} {{.Config.Image}}' "$id" 2>/dev/null || true
}

frontend_rollback() {
  local src="$1" debug="$2" prev_name="$3"
  debug_log "$debug" "ROLLBACK frontend to wg-frontend-prev:local name=$prev_name"
  if [[ -n "$prev_name" ]]; then
    docker tag wg-frontend-prev:local "$prev_name" 2>&1 | tee -a "$debug" || true
  fi
  docker compose -f "$src/docker-compose.yml" --project-directory "$src" up -d --no-build frontend 2>&1 | tee -a "$debug"
}

build_history_json() {
  python3 - "$@" <<'PY'
import json, sys
ts, host, kind, src_base, since, sha, old, new, result, detail, commits_raw, steps_json, rb_json = sys.argv[1:14]
commits = []
for line in commits_raw.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t", 2)
    if len(parts) < 3:
        continue
    commits.append({"sha": parts[0], "date": parts[1], "subject": parts[2]})
try:
    steps = json.loads(steps_json) if steps_json else []
except json.JSONDecodeError:
    steps = []
try:
    rollback = json.loads(rb_json) if rb_json else {"attempted": False, "ok": None, "detail": ""}
except json.JSONDecodeError:
    rollback = {"attempted": False, "ok": None, "detail": ""}
row = {
    "ts": ts,
    "host": host,
    "script": kind,
    "baseline": {"source": src_base, "since": since or None, "sha": sha or None},
    "oldSha": old,
    "newSha": new,
    "commits": commits,
    "result": result,
    "detail": detail,
    "steps": steps,
    "rollback": rollback,
}
print(json.dumps(row, separators=(",", ":")))
PY
}

friendly_content_name() {
  local s="$1"
  if echo "$s" | grep -qiE '^\[no ci\][[:space:]]*update schema'; then
    printf '%s\n' "Official rules dump (source books, spells, feats)"
    return
  fi
  if echo "$s" | grep -qiE '^fix\(content\):'; then
    printf 'Fix: %s\n' "$(echo "$s" | sed -E 's/^[Ff]ix\(content\):[[:space:]]*//')"
    return
  fi
  printf '%s\n' "$s"
}

short_sha() {
  local sha="$1"
  printf '%s\n' "${sha:0:12}"
}

pause_check() {
  local debug="$1" prompt="$2" skip="${3:-0}"
  if [[ "$skip" == "1" ]]; then
    debug_log "$debug" "pause skipped: $prompt"
    return 0
  fi
  printf '\n'
  printf '%s\n' "$prompt"
  debug_log "$debug" "pause: $prompt"
  read -r -p "Press Enter to continue, or Ctrl+C to abort " </dev/tty
}

show_last_content_update() {
  local debug="$1"
  local hist
  hist="$(last_successful_history content || true)"
  printf '\n=== Last content update of this DB ===\n'
  if [[ -z "$hist" ]]; then
    printf '  (none recorded yet — first run or no successful apply on this host)\n'
    debug_log "$debug" "last content update: none"
    return 0
  fi
  python3 - "$hist" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
sha = r.get("newSha") or ""
print("  When (UTC):     %s" % (r.get("ts") or ""))
print("  Internal id:    %s" % sha)
print("  Short id:       %s" % sha[:12])
commits = r.get("commits") or []
if commits:
    subj = commits[-1].get("subject") or ""
    low = subj.lower()
    name = subj
    if low.startswith("[no ci]") and "update schema" in low:
        name = "Official rules dump (source books, spells, feats)"
    print("  Friendly name:  %s" % name)
PY
  debug_log "$debug" "last content update $hist"
}

show_content_update_list() {
  local debug="$1" commits_raw="$2"
  local n
  n="$(printf '%s\n' "$commits_raw" | grep -c . || true)"
  printf '\n=== Content updates pulled from git: %s ===\n' "$n"
  local i=0
  while IFS=$'\t' read -r sha date subject; do
    [[ -z "${sha:-}" ]] && continue
    i=$((i + 1))
    local friendly
    friendly="$(friendly_content_name "$subject")"
    printf '  %3d. internal %s   external: %s\n' "$i" "$(short_sha "$sha")" "$friendly"
    printf '       git: %s\n' "$subject"
    printf '       date: %s\n' "$date"
    debug_log "$debug" "pulled $i/$n $(short_sha "$sha") $friendly"
  done <<<"$commits_raw"
}

test_content_batch_json() {
  local debug="$1" commits_raw="$2"
  if python3 - "$commits_raw" <<'PY'
import json, sys
raw = sys.argv[1]
batch = []
for line in raw.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t", 2)
    if len(parts) < 3:
        raise SystemExit("bad row: " + line)
    sha, date, subject = parts
    if not sha or not subject:
        raise SystemExit("missing sha or subject")
    low = subject.lower()
    name = subject
    if low.startswith("[no ci]") and "update schema" in low:
        name = "Official rules dump (source books, spells, feats)"
    elif low.startswith("fix(content):"):
        name = "Fix: " + subject.split(":", 1)[-1].strip()
    batch.append({
        "internalId": sha,
        "shortId": sha[:12],
        "externalName": name,
        "gitSubject": subject,
        "date": date,
    })
text = json.dumps(batch)
json.loads(text)
print(text)
PY
  then
    printf 'json looks clean.\n'
    debug_log "$debug" "content batch json valid"
    return 0
  fi
  printf 'json look invalid. see debug log\n'
  debug_log "$debug" "content batch json INVALID"
  return 1
}

write_content_status() {
  local src="$1" applied="$2" commits_raw="$3"
  local origin origin_date applied_date behind path
  origin="$(git_c "$src" rev-parse origin/main)"
  origin_date="$(git_c "$src" log -1 --format=%cI origin/main)"
  applied_date="$(git_c "$src" log -1 --format=%cI "$applied")"
  behind="$(git_c "$src" rev-list --count "${applied}..origin/main")"
  path="$(init_log_dir)/content-status.json"
  python3 - "$path" "$applied" "$applied_date" "$origin" "$origin_date" "$behind" "$(hostname)" "$commits_raw" <<'PY'
import json, sys, datetime
path, applied, applied_date, origin, origin_date, behind, host, commits_raw = sys.argv[1:9]
batch = []
for line in commits_raw.splitlines():
    if not line.strip():
        continue
    sha, date, subject = line.split("\t", 2)
    name = subject
    low = subject.lower()
    if low.startswith("[no ci]") and "update schema" in low:
        name = "Official rules dump (source books, spells, feats)"
    elif low.startswith("fix(content):"):
        name = "Fix: " + subject.split(":", 1)[-1].strip()
    batch.append({
        "internalId": sha,
        "shortId": sha[:12],
        "externalName": name,
        "gitSubject": subject,
        "date": date,
    })
behind_n = int(behind or 0)
status = {
    "updatedAtUtc": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": host,
    "dbAppliedSha": applied,
    "dbAppliedDate": applied_date,
    "gitOriginMainSha": origin,
    "gitOriginMainDate": origin_date,
    "commitsBehindOriginMain": behind_n,
    "current": behind_n == 0,
    "lastBatch": batch,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(status, f, indent=2)
    f.write("\n")
print(path)
print(str(behind_n))
print("1" if behind_n == 0 else "0")
PY
  printf '\n=== Content update log (where we stand vs git) ===\n'
  printf '  DB applied:      %s (%s)\n' "$applied" "$applied_date"
  printf '  Git origin/main: %s (%s)\n' "$origin" "$origin_date"
  if [[ "$behind" == "0" ]]; then
    printf '  Status:          CURRENT — DB matches origin/main\n'
  else
    printf '  Status:          %s commit(s) behind origin/main\n' "$behind"
  fi
  printf '  Wrote %s\n' "$path"
}

repair_wg_grants() {
  local src="$1"
  src="$(cd "$src" && pwd)"
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf 'Repairing GoTrue / PostgREST grants (no content swap)...\n'
  WG_SRC="$src" WG_REPAIR_GRANTS_ONLY=1 WG_DEBUG_LOG="$(init_log_dir)/debug-content.log" \
    "$here/wg-reload-official-content.sh"
}

run_wg_update() {
  local src="$1" kind="$2" force="${3:-0}" since_override="${4:-}" yes="${5:-0}"
  src="$(cd "$src" && pwd)"
  local dir debug
  dir="$(init_log_dir)"
  debug="$dir/debug-${kind}.log"
  : >"$debug"
  local total=6
  local steps_json='[]'
  local rb_json='{"attempted":false,"ok":null,"detail":""}'
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  debug_log "$debug" "script=$kind src=$src force=$force since=$since_override verbose=1 debugLog=$debug"
  printf 'Debug log: %s\n' "$debug"
  repo_snapshot "$src" "$debug"
  step_log "$debug" 1 "$total" assert_git START
  assert_git_src "$src"
  step_log "$debug" 1 "$total" assert_git OK

  step_log "$debug" 2 "$total" fetch START
  local fetch_out
  fetch_out="$(git_c "$src" fetch origin 2>&1)" || {
    step_log "$debug" 2 "$total" fetch FAIL
    debug_log "$debug" "git fetch failed: $fetch_out"
    return 1
  }
  debug_log "$debug" "git fetch origin"$'\n'"$fetch_out"
  step_log "$debug" 2 "$total" fetch OK

  local old_sha
  old_sha="$(head_sha "$src")"
  local base_line source base_since base_sha
  base_line="$(resolve_baseline "$src" "$kind" "$since_override")"
  IFS=$'\t' read -r source base_since base_sha <<<"$base_line"
  debug_log "$debug" "baseline source=$source since=$base_since sha=$base_sha"

  step_log "$debug" 3 "$total" window START
  local commits_raw
  commits_raw="$(commits_in_window "$src" "$kind" "$base_sha" "$base_since" || true)"
  debug_log "$debug" "window commits:"
  if [[ -n "$commits_raw" ]]; then
    debug_log "$debug" "$commits_raw"
  else
    debug_log "$debug" "(none)"
  fi
  step_log "$debug" 3 "$total" window OK

  dirty="$(worktree_real_dirty "$src" "$debug" || true)"
  if [[ -n "$dirty" ]]; then
    printf 'Work tree is dirty (only .env is allowed). see debug log\n'
    debug_log "$debug" "dirty work tree (only .env is allowed): $dirty"
    return 1
  fi

  if [[ "$kind" == "content" ]]; then
    show_last_content_update "$debug"
    pause_check "$debug" "Check: last DB content update looks right?" "$yes"
    show_content_update_list "$debug" "$commits_raw"
    local pulled
    pulled="$(printf '%s\n' "$commits_raw" | grep -c . || true)"
    pause_check "$debug" "Check: $pulled content update(s) pulled from git. Continue?" "$yes"
    local walk=0
    while IFS=$'\t' read -r sha date subject; do
      [[ -z "${sha:-}" ]] && continue
      walk=$((walk + 1))
      printf '\nApplying %s/%s ...\n' "$walk" "$pulled"
      printf '  internal: %s\n' "$sha"
      printf '  external: %s (%s)\n' "$(friendly_content_name "$subject")" "$(short_sha "$sha")"
      pause_check "$debug" "Include this content update ($walk/$pulled)?" "$yes"
    done <<<"$commits_raw"
    if [[ -n "$commits_raw" || "$force" == "1" ]]; then
      if ! test_content_batch_json "$debug" "$commits_raw"; then
        return 1
      fi
      pause_check "$debug" "json looks clean, update the db?" "$yes"
    fi
  fi

  local ts host
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  host="$(hostname)"
  local new_sha="$old_sha"
  local result="skipped"
  local detail=""

  if [[ -z "$commits_raw" && "$force" != "1" ]]; then
    if [[ "$kind" == "content" ]]; then
      detail="no-content-changes"
    else
      detail="content-only-or-empty"
    fi
    append_history "$(build_history_json "$ts" "$host" "$kind" "$source" "$base_since" "$base_sha" "$old_sha" "$new_sha" "$result" "$detail" "$commits_raw" "$steps_json" "$rb_json")"
    debug_log "$debug" "skipped: $detail"
    return 0
  fi

  local dirty
  dirty="$(worktree_real_dirty "$src" "$debug" || true)"
  if [[ -n "$dirty" ]]; then
    result="failed"
    detail="dirty work tree (only .env is allowed): $dirty"
    append_history "$(build_history_json "$ts" "$host" "$kind" "$source" "$base_since" "$base_sha" "$old_sha" "$new_sha" "$result" "$detail" "$commits_raw" "$steps_json" "$rb_json")"
    debug_log "$debug" "$detail"
    return 1
  fi

  step_log "$debug" 4 "$total" merge START
  local merge_out
  if ! merge_out="$(git_c "$src" merge --ff-only origin/main 2>&1)"; then
    new_sha="$(head_sha "$src")"
    result="failed"
    detail="ff-only merge failed: $merge_out"
    step_log "$debug" 4 "$total" merge FAIL
    append_history "$(build_history_json "$ts" "$host" "$kind" "$source" "$base_since" "$base_sha" "$old_sha" "$new_sha" "$result" "$detail" "$commits_raw" "$steps_json" "$rb_json")"
    debug_log "$debug" "$detail"
    return 1
  fi
  debug_log "$debug" "git merge --ff-only origin/main"$'\n'"$merge_out"
  new_sha="$(head_sha "$src")"
  step_log "$debug" 4 "$total" merge OK "HEAD $old_sha -> $new_sha"

  step_log "$debug" 5 "$total" apply START
  if [[ "$kind" == "content" ]]; then
    local backup
    backup="$dir/backups/$(date -u +"%Y%m%dT%H%M%SZ")-pre-content.dump"
    mkdir -p "$dir/backups"
    local apply_out
    if ! apply_out="$(WG_SRC="$src" WG_BACKUP_PATH="$backup" WG_DEBUG_LOG="$debug" "$here/wg-reload-official-content.sh" 2>&1)"; then
      debug_log "$debug" "$apply_out"
      step_log "$debug" 5 "$total" apply FAIL
      step_log "$debug" 6 "$total" rollback START
      if git_rollback "$src" "$old_sha" "$debug"; then
        rb_json='{"attempted":true,"ok":true,"detail":"git reset; DB restore inside wg-reload-official-content.sh"}'
        step_log "$debug" 6 "$total" rollback OK
      else
        rb_json="{\"attempted\":true,\"ok\":false,\"detail\":\"git reset failed; backup $backup\"}"
        step_log "$debug" 6 "$total" rollback FAIL
      fi
      result="failed"
      detail="official content reload failed: $apply_out"
      new_sha="$(head_sha "$src")"
      append_history "$(build_history_json "$ts" "$host" "$kind" "$source" "$base_since" "$base_sha" "$old_sha" "$new_sha" "$result" "$detail" "$commits_raw" "$steps_json" "$rb_json")"
      return 1
    fi
    debug_log "$debug" "$apply_out"
    detail="swapped official content; user data preserved; backup=$backup"
  else
    local before after prev_id prev_name
    before="$(frontend_image "$src" || true)"
    prev_id="${before%% *}"
    prev_name="${before#* }"
    debug_log "$debug" "frontend before imageId=$prev_id imageName=$prev_name"
    if [[ -n "$prev_id" ]]; then
      docker tag "$prev_id" wg-frontend-prev:local 2>&1 | tee -a "$debug" || true
    fi
    local apply_out
    if ! apply_out="$(docker compose -f "$src/docker-compose.yml" --project-directory "$src" up -d --build frontend 2>&1)"; then
      debug_log "$debug" "$apply_out"
      step_log "$debug" 5 "$total" apply FAIL
      step_log "$debug" 6 "$total" rollback START
      local img_ok=1 git_ok=1
      if [[ -n "$prev_id" ]]; then
        frontend_rollback "$src" "$debug" "$prev_name" || img_ok=0
      fi
      git_rollback "$src" "$old_sha" "$debug" || git_ok=0
      if [[ "$img_ok" == "1" && "$git_ok" == "1" ]]; then
        rb_json='{"attempted":true,"ok":true,"detail":"image and git rolled back"}'
        step_log "$debug" 6 "$total" rollback OK
      else
        rb_json="{\"attempted\":true,\"ok\":false,\"detail\":\"imageRollback=$img_ok gitRollback=$git_ok\"}"
        step_log "$debug" 6 "$total" rollback FAIL
      fi
      result="failed"
      detail="docker compose rebuild failed: $apply_out"
      new_sha="$(head_sha "$src")"
      append_history "$(build_history_json "$ts" "$host" "$kind" "$source" "$base_since" "$base_sha" "$old_sha" "$new_sha" "$result" "$detail" "$commits_raw" "$steps_json" "$rb_json")"
      return 1
    fi
    debug_log "$debug" "$apply_out"
    after="$(frontend_image "$src" || true)"
    debug_log "$debug" "frontend after $after"
    detail="rebuilt frontend $before -> $after"
  fi

  step_log "$debug" 5 "$total" apply OK
  step_log "$debug" 6 "$total" commit OK "keep HEAD $new_sha"
  result="applied"
  append_history "$(build_history_json "$ts" "$host" "$kind" "$source" "$base_since" "$base_sha" "$old_sha" "$new_sha" "$result" "$detail" "$commits_raw" "$steps_json" "$rb_json")"
  debug_log "$debug" "applied $old_sha -> $new_sha: $detail"
  if [[ "$kind" == "content" ]]; then
    write_content_status "$src" "$new_sha" "$commits_raw"
  fi
  return 0
}
