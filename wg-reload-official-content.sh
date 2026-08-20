#!/usr/bin/env bash
# Reload official WG book content (content_source.user_id IS NULL) without
# dropping public or touching user/character/campaign/homebrew rows.
# Never calls create-db-docker.sh.
#
# Env:
#   WG_SRC              wanderers-guide checkout (required)
#   WG_DB_CONTAINER     default wanderers-guide-db-1
#   WG_BACKUP_PATH      custom-format dump path (required unless repair-only)
#   WG_DEBUG_LOG        optional extra log file
#   WG_REPAIR_GRANTS_ONLY=1   fix/check GoTrue + PostgREST grants; no content swap
set -euo pipefail

# Git Bash otherwise rewrites /d/foo -> D:\d\foo when calling docker.exe
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SRC="${WG_SRC:?WG_SRC is required}"
CONTAINER="${WG_DB_CONTAINER:-wanderers-guide-db-1}"
BACKUP_PATH="${WG_BACKUP_PATH:-}"
REPAIR_ONLY="${WG_REPAIR_GRANTS_ONLY:-0}"

# docker.exe on Windows wants D:/... not /d/...
docker_host_path() {
  local p="$1"
  if [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
    local drive
    drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
    printf '%s:/%s\n' "$drive" "${BASH_REMATCH[2]}"
  else
    printf '%s\n' "${p//\\//}"
  fi
}
BACKUP_PATH_DOCKER=""
if [[ -n "$BACKUP_PATH" ]]; then
  BACKUP_PATH_DOCKER="$(docker_host_path "$BACKUP_PATH")"
fi
DB_USER="${DB_USER:-postgres}"
LIVE_DB="${LIVE_DB:-postgres}"
STAGE_DB="wg_incoming"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SRC/data"
MIN_BACKUP_BYTES="${WG_MIN_BACKUP_BYTES:-1024}"

CONTENT_TABLES=(
  trait
  language
  ability_block
  ancestry
  background
  class
  class_archetype
  archetype
  item
  spell
  creature
  versatile_heritage
  content_update
)

log() {
  local line="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  printf '%s\n' "$line"
  if [[ -n "${WG_DEBUG_LOG:-}" ]]; then
    printf '%s\n' "$line" >>"$WG_DEBUG_LOG"
  fi
}

step() {
  local n="$1" total="$2" name="$3" status="$4"
  shift 4
  log "STEP $n/$total $status $name $*"
}

psql_exec() {
  local db="$1"
  shift
  local out
  set +e
  out="$(docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$db" -v ON_ERROR_STOP=1 "$@" 2>&1 <&0)"
  local code=$?
  set -e
  printf '%s\n' "$out"
  if [[ "$code" -ne 0 ]] || grep -q '^ERROR:' <<<"$out"; then
    log "psql failed db=$db exit=$code"
    return 1
  fi
  return 0
}

psql_live() {
  psql_exec "$LIVE_DB" "$@"
}

psql_stage() {
  psql_exec "$STAGE_DB" "$@"
}

psql_live_q() {
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$LIVE_DB" -v ON_ERROR_STOP=1 -q "$@"
}

psql_stage_q() {
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$STAGE_DB" -v ON_ERROR_STOP=1 -q "$@"
}

assert_container() {
  docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || {
    log "FAIL db container '$CONTAINER' is not running"
    return 1
  }
}

count_sources() {
  local db="$1"
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$db" -At -c \
    "SELECT 'official=' || COUNT(*) FILTER (WHERE user_id IS NULL) || ' user=' || COUNT(*) FILTER (WHERE user_id IS NOT NULL) FROM public.content_source;"
}

# Stable fingerprint of user-owned rows only. Official catalog tables are excluded.
# If this string changes after a content swap, we roll back.
user_data_fingerprint() {
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$LIVE_DB" -At -v ON_ERROR_STOP=1 <<'SQL'
SELECT md5(concat_ws('|',
  (SELECT COUNT(*)::text FROM public."character"),
  (SELECT COALESCE(md5(string_agg(t.fp, ',' ORDER BY t.id)), 'empty') FROM (
     SELECT id,
            md5(concat_ws(chr(30),
              user_id::text, name, level::text, experience::text,
              COALESCE(inventory::text,''), COALESCE(notes::text,''),
              COALESCE(details::text,''), COALESCE(custom_operations::text,''),
              COALESCE(meta_data::text,''), COALESCE(options::text,''),
              COALESCE(variants::text,''), COALESCE(content_sources::text,''),
              COALESCE(operation_data::text,''), COALESCE(spells::text,''),
              COALESCE(companions::text,''), COALESCE(campaign_id::text,'')
            )) AS fp
     FROM public."character"
  ) t),
  (SELECT COUNT(*)::text FROM public.public_user),
  (SELECT COALESCE(md5(string_agg(id::text || ':' || user_id::text, ',' ORDER BY id)), 'empty') FROM public.public_user),
  (SELECT COUNT(*)::text FROM public.campaign),
  (SELECT COALESCE(md5(string_agg(id::text || ':' || user_id::text || ':' || COALESCE(join_key,''), ',' ORDER BY id)), 'empty') FROM public.campaign),
  (SELECT COUNT(*)::text FROM public.campaign_join_grant),
  (SELECT COALESCE(md5(string_agg(user_id::text || ':' || campaign_id::text, ',' ORDER BY user_id, campaign_id)), 'empty') FROM public.campaign_join_grant),
  (SELECT COUNT(*)::text FROM public.encounter),
  (SELECT COALESCE(md5(string_agg(id::text || ':' || user_id::text || ':' || COALESCE(combatants::text,''), ',' ORDER BY id)), 'empty') FROM public.encounter),
  (SELECT COUNT(*)::text FROM public.content_source WHERE user_id IS NOT NULL),
  (SELECT COALESCE(md5(string_agg(id::text || ':' || user_id::text, ',' ORDER BY id)), 'empty') FROM public.content_source WHERE user_id IS NOT NULL),
  (SELECT COUNT(*)::text FROM public.ability_block t JOIN public.content_source cs ON cs.id = t.content_source_id WHERE cs.user_id IS NOT NULL),
  (SELECT COUNT(*)::text FROM public.item t JOIN public.content_source cs ON cs.id = t.content_source_id WHERE cs.user_id IS NOT NULL),
  (SELECT COUNT(*)::text FROM public.spell t JOIN public.content_source cs ON cs.id = t.content_source_id WHERE cs.user_id IS NOT NULL)
));
SQL
}

backup_live() {
  mkdir -p "$(dirname "$BACKUP_PATH")"
  local remote="/tmp/wg-pre-content.dump"
  log "pg_dump -Fc $LIVE_DB schemas public,auth -> $BACKUP_PATH"
  docker exec "$CONTAINER" pg_dump -U "$DB_USER" -Fc -d "$LIVE_DB" -n public -n auth -f "$remote"
  docker cp "$CONTAINER:$remote" "$BACKUP_PATH_DOCKER"
  docker exec "$CONTAINER" rm -f "$remote"
  local size
  size="$(wc -c <"$BACKUP_PATH" | tr -d ' ')"
  log "backup bytes=$size path=$BACKUP_PATH"
  if [[ "$size" -lt "$MIN_BACKUP_BYTES" ]]; then
    log "FAIL backup too small ($size < $MIN_BACKUP_BYTES)"
    return 1
  fi
}

# pg_restore --clean --no-acl --no-owner on auth drops GoTrue's GRANTs
# (auth.identities / auth.users / auth.refresh_tokens → SQLSTATE 42501).
# We dump auth for emergency use but roll back public only.
restore_live() {
  log "ROLLBACK pg_restore --clean --if-exists -n public $BACKUP_PATH"
  local remote="/tmp/wg-pre-content.dump"
  docker cp "$BACKUP_PATH_DOCKER" "$CONTAINER:$remote"
  docker exec "$CONTAINER" pg_restore -U "$DB_USER" -d "$LIVE_DB" --clean --if-exists --no-owner --no-acl -n public "$remote"
  docker exec "$CONTAINER" rm -f "$remote"
  repair_supabase_privileges
  log "ROLLBACK restore finished counts=$(count_sources "$LIVE_DB")"
}

# Recreate PostgREST + GoTrue privileges that --no-acl restore (or a bad
# dump) strips. Safe to re-run. Does not touch row data.
repair_supabase_privileges() {
  log "repair supabase / GoTrue privileges"
  psql_live <<'SQL'
-- PostgREST roles (same as data/create-db-docker.sh step 6)
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;

-- GoTrue connects as supabase_auth_admin (GOTRUE_DB_DATABASE_URL).
GRANT USAGE, CREATE ON SCHEMA auth TO supabase_auth_admin, postgres;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA auth TO supabase_auth_admin, postgres;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA auth TO supabase_auth_admin, postgres;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA auth TO supabase_auth_admin, postgres;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON TABLES TO supabase_auth_admin, postgres;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON SEQUENCES TO supabase_auth_admin, postgres;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON FUNCTIONS TO supabase_auth_admin, postgres;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dashboard_user') THEN
    EXECUTE 'GRANT USAGE, CREATE ON SCHEMA auth TO dashboard_user';
    EXECUTE 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA auth TO dashboard_user';
    EXECUTE 'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA auth TO dashboard_user';
    EXECUTE 'GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA auth TO dashboard_user';
  END IF;
END $$;

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.relname, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'auth' AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
  LOOP
    IF r.relkind = 'S' THEN
      EXECUTE format('ALTER SEQUENCE auth.%I OWNER TO supabase_auth_admin', r.relname);
    ELSE
      EXECUTE format('ALTER TABLE auth.%I OWNER TO supabase_auth_admin', r.relname);
    END IF;
  END LOOP;
  FOR r IN
    SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'auth'
  LOOP
    EXECUTE format('ALTER FUNCTION auth.%I(%s) OWNER TO supabase_auth_admin', r.proname, r.args);
  END LOOP;
END $$;
SQL

  if [[ -f "$DATA_DIR/auth-trigger.sql" ]]; then
    log "reinstall auth → public_user trigger"
    psql_live_q <"$DATA_DIR/auth-trigger.sql"
  fi
}

assert_auth_access() {
  log "check supabase_auth_admin can read auth.identities / users / refresh_tokens"
  psql_live <<'SQL'
SET ROLE supabase_auth_admin;
SELECT
  (SELECT COUNT(*) FROM auth.identities) AS identities,
  (SELECT COUNT(*) FROM auth.users) AS users,
  (SELECT COUNT(*) FROM auth.refresh_tokens) AS refresh_tokens;
RESET ROLE;
SQL
}

load_stage_db() {
  log "recreate database $STAGE_DB"
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$LIVE_DB" -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$STAGE_DB';
DROP DATABASE IF EXISTS $STAGE_DB;
CREATE DATABASE $STAGE_DB;
SQL

  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$STAGE_DB" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'github') THEN
    CREATE ROLE github;
  END IF;
END $$;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
SQL

  log "load schema.sql into $STAGE_DB"
  sed -e '/^\\restrict /d' -e '/^\\unrestrict /d' -e '/^CREATE TRIGGER /d' "$DATA_DIR/schema.sql" \
    | psql_stage_q

  log "load data.sql into $STAGE_DB (may take a minute)"
  sed -e '/^\\restrict /d' -e '/^\\unrestrict /d' "$DATA_DIR/data.sql" \
    | psql_stage_q

  log "stage counts=$(count_sources "$STAGE_DB")"
}

assert_user_data_unchanged() {
  local before="$1" when="$2"
  local after
  after="$(user_data_fingerprint)"
  log "user-data fingerprint $when=$after"
  if [[ "$after" != "$before" ]]; then
    log "FAIL user-data fingerprint changed ($when). before=$before after=$after"
    return 1
  fi
  log "user-data fingerprint unchanged ($when)"
}

table_cols() {
  local db="$1" table="$2"
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$db" -At -v ON_ERROR_STOP=1 -c \
    "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${table}' AND is_generated = 'NEVER' ORDER BY ordinal_position;"
}

shared_cols() {
  local table="$1"
  local live stage col
  live="$(table_cols "$LIVE_DB" "$table")"
  stage="$(table_cols "$STAGE_DB" "$table")"
  local out=""
  while IFS= read -r col; do
    [[ -z "$col" ]] && continue
    if grep -Fxq "$col" <<<"$stage"; then
      if [[ -n "$out" ]]; then out+=","; fi
      out+="\"${col}\""
    fi
  done <<<"$live"
  if [[ -z "$out" ]]; then
    log "FAIL no shared columns for $table"
    return 1
  fi
  printf '%s\n' "$out"
}

copy_pipe() {
  local label="$1"
  local stage_sql="$2"
  local live_sql="$3"
  local tmp
  tmp="$(mktemp)"
  set +e
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$STAGE_DB" -v ON_ERROR_STOP=1 -c "$stage_sql" \
    | docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$LIVE_DB" -v ON_ERROR_STOP=1 \
      -c "SET session_replication_role = replica" \
      -c "$live_sql" \
    >"$tmp" 2>&1
  set +u
  local c0="${PIPESTATUS[0]}"
  local c1="${PIPESTATUS[1]}"
  set -eu
  c0="${c0:-1}"
  c1="${c1:-1}"
  cat "$tmp"
  if grep -q '^ERROR:' "$tmp"; then
    log "FAIL copy $label stage_exit=$c0 live_exit=$c1"
    rm -f "$tmp"
    return 1
  fi
  if grep -q '^COPY [0-9][0-9]*' "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  log "FAIL copy $label (no COPY n) stage_exit=$c0 live_exit=$c1"
  rm -f "$tmp"
  return 1
}

copy_official_table() {
  local table="$1"
  local cols
  cols="$(shared_cols "$table")"
  log "copy official $table cols=$cols"
  copy_pipe "$table" \
    "\\COPY (SELECT ${cols} FROM public.${table} t WHERE EXISTS (SELECT 1 FROM public.content_source cs WHERE cs.id = t.content_source_id AND cs.user_id IS NULL)) TO STDOUT" \
    "\\COPY public.${table} (${cols}) FROM STDIN"
}

copy_official_sources() {
  local cols
  cols="$(shared_cols content_source)"
  log "copy official content_source cols=$cols"
  copy_pipe content_source \
    "\\COPY (SELECT ${cols} FROM public.content_source WHERE user_id IS NULL) TO STDOUT" \
    "\\COPY public.content_source (${cols}) FROM STDIN"
}

swap_official() {
  log "delete official rows only (content_source.user_id IS NULL). character/public_user/campaign/encounter/homebrew are not in this SQL."
  # replica role skips FK ON DELETE SET NULL (versatile_heritage.heritage_id is NOT NULL).
  psql_live <<'SQL'
BEGIN;
SET LOCAL session_replication_role = replica;
DELETE FROM public.versatile_heritage t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.class_archetype t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.ability_block t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.ancestry t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.archetype t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.background t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.class t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.content_update t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.creature t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.item t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.language t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.spell t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.trait t USING public.content_source cs WHERE t.content_source_id = cs.id AND cs.user_id IS NULL;
DELETE FROM public.content_source WHERE user_id IS NULL;
COMMIT;
SQL

  local leftover
  leftover="$(docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$LIVE_DB" -At -c "SELECT COUNT(*) FROM public.content_source WHERE user_id IS NULL;")"
  log "official content_source remaining after delete=$leftover"
  if [[ "$leftover" != "0" ]]; then
    log "FAIL official content_source delete did not clear ($leftover left)"
    return 1
  fi

  copy_official_sources || return 1
  local table
  for table in "${CONTENT_TABLES[@]}"; do
    copy_official_table "$table" || return 1
  done

  psql_live <<'SQL'
SELECT setval(
  pg_get_serial_sequence('public.content_source', 'id'),
  COALESCE((SELECT MAX(id) FROM public.content_source), 1),
  true
);
SQL
  log "live counts after swap=$(count_sources "$LIVE_DB")"
}

replay_migrations() {
  local migration
  for migration in "$SRC"/supabase/migrations/*.sql; do
    [[ -f "$migration" ]] || continue
    log "migration $(basename "$migration") (re-runnable / named)"
    psql_live_q <"$migration"
  done
}

drop_stage() {
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$LIVE_DB" -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$STAGE_DB';
DROP DATABASE IF EXISTS $STAGE_DB;
SQL
}

if [[ "$REPAIR_ONLY" == "1" ]]; then
  step 1 2 assert_container START
  assert_container
  step 1 2 assert_container OK "container=$CONTAINER"
  step 2 2 repair_grants START
  repair_supabase_privileges
  assert_auth_access
  step 2 2 repair_grants OK
  log "DONE privilege repair only; no content swap"
  exit 0
fi

if [[ -z "$BACKUP_PATH" ]]; then
  log "FAIL WG_BACKUP_PATH is required for a content reload"
  exit 1
fi

TOTAL=8
need_restore=0
USER_FP=""

step 1 "$TOTAL" assert_container START
assert_container
repair_supabase_privileges
assert_auth_access
USER_FP="$(user_data_fingerprint)"
step 1 "$TOTAL" assert_container OK "container=$CONTAINER live_counts=$(count_sources "$LIVE_DB") user_fp=$USER_FP"

step 2 "$TOTAL" backup START
backup_live
need_restore=1
step 2 "$TOTAL" backup OK

step 3 "$TOTAL" stage START
rollback_or_die() {
  if restore_live; then
    log "ROLLBACK ok; user/character data should match pre-apply backup"
    return 0
  fi
  log "FATAL ROLLBACK FAILED. Leave $BACKUP_PATH intact and restore manually: pg_restore --clean --if-exists"
  exit 2
}
trap 'log "unhandled error; restoring backup"; rollback_or_die; exit 1' ERR

if ! load_stage_db; then
  step 3 "$TOTAL" stage FAIL
  rollback_or_die
  exit 1
fi
step 3 "$TOTAL" stage OK

step 4 "$TOTAL" swap START
if ! swap_official; then
  step 4 "$TOTAL" swap FAIL
  rollback_or_die
  drop_stage || true
  exit 1
fi
if ! assert_user_data_unchanged "$USER_FP" after-swap; then
  step 4 "$TOTAL" swap FAIL "user data changed"
  rollback_or_die
  drop_stage || true
  exit 1
fi
step 4 "$TOTAL" swap OK

step 5 "$TOTAL" migrations START
if ! replay_migrations; then
  step 5 "$TOTAL" migrations FAIL
  rollback_or_die
  drop_stage || true
  exit 1
fi
if ! assert_user_data_unchanged "$USER_FP" after-migrations; then
  step 5 "$TOTAL" migrations FAIL "user data changed"
  rollback_or_die
  drop_stage || true
  exit 1
fi
step 5 "$TOTAL" migrations OK

step 6 "$TOTAL" drop_stage START
drop_stage
step 6 "$TOTAL" drop_stage OK

step 7 "$TOTAL" verify_user_data START
if ! assert_user_data_unchanged "$USER_FP" after-commit; then
  step 7 "$TOTAL" verify_user_data FAIL
  rollback_or_die
  exit 1
fi
step 7 "$TOTAL" verify_user_data OK "user/character/campaign/encounter/homebrew unchanged"

step 8 "$TOTAL" repair_grants START
repair_supabase_privileges
if ! assert_auth_access; then
  step 8 "$TOTAL" repair_grants FAIL
  rollback_or_die
  exit 1
fi
step 8 "$TOTAL" repair_grants OK "supabase_auth_admin can read auth.identities"

log "DONE official content reload; user data fingerprint=$USER_FP"
exit 0
