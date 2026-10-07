#!/bin/bash
# Behaviour tests for postgres_dba reports and interactive routines.
#
# Unlike the smoke tests (which only check that reports run), these tests
# verify what the reports recommend and what the interactive routines change.
# They create and drop objects, so run them only against a disposable
# database, connected as a superuser through the standard libpq variables:
#
#   PGHOST=localhost PGUSER=postgres PGDATABASE=test test/behavior.sh

set -euo pipefail

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$ROOT"

export PAGER=cat
PSQL=(psql --no-psqlrc -v ON_ERROR_STOP=1)
SCHEMA=postgres_dba_behavior
failures=0

pass() { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; failures=$((failures + 1)); }
check() { # check <description> <command...>
  local description="$1"; shift
  if "$@"; then pass "$description"; else fail "$description"; fi
}
sql() { "${PSQL[@]}" -Atqc "$1"; }
injection_marker_absent() { [[ -z "$(sql "select to_regclass('public.postgres_dba_injection_marker')")" ]]; }

server_version_num=$(sql "show server_version_num")

cleanup() {
  set +e
  sql "drop schema if exists $SCHEMA cascade" > /dev/null 2>&1
  sql "drop table if exists public.postgres_dba_injection_marker" > /dev/null 2>&1
  sql "drop role if exists \"postgres_dba_o'test\", postgres_dba_invalid, postgres_dba_alter,
    postgres_dba_seed1, postgres_dba_seed2, postgres_dba_target, postgres_dba_op_created,
    postgres_dba_operator" > /dev/null 2>&1
  sql "select pg_terminate_backend(pid) from pg_stat_activity where application_name like 'postgres_dba_behavior%'" > /dev/null 2>&1
  [[ "${created_intarray:-false}" == true ]] && sql "drop extension if exists intarray" > /dev/null 2>&1
  set -e
}
trap cleanup EXIT
cleanup

###############################################################################
echo "Index recommendations (i2, i3, i5)"

# intarray makes "smallint[] <@ smallint[]" ambiguous; the reports must work with it.
created_intarray=false
if [[ "$(sql "select count(*) from pg_extension where extname = 'intarray'")" == 0 ]] \
  && [[ "$(sql "select count(*) from pg_available_extensions where name = 'intarray'")" == 1 ]]; then
  sql "create extension intarray" > /dev/null && created_intarray=true
fi
check "intarray is installed for the index tests" \
  [ "$(sql "select count(*) from pg_extension where extname = 'intarray'")" == 1 ]

"${PSQL[@]}" -q <<SQL
create schema $SCHEMA;
set search_path = $SCHEMA;
create table coverage (a int, b int);
create index cov_a on coverage (a);
create index cov_ab on coverage (a, b);
create table uniq (a int);
create index uniq_plain on uniq (a);
create unique index uniq_unique on uniq (a);
create table pk (a int, b int, primary key (a, b));
create unique index pk_unique_a on pk (a);
create table sorting (a int, b int);
create index sort_asc on sorting (a, b);
create index sort_mixed on sorting (a, b desc);
create table wide (c1 int, c2 int, c3 int, c4 int, c5 int, c6 int, c7 int, c8 int, c9 int, c10 int, c11 int);
create index wide_c1 on wide (c1);
create index wide_c10 on wide (c10, c2);
create table dup (a int);
create index dup_1 on dup (a);
create index dup_2 on dup (a);
create table incl (a int, b int, c int);
create index incl_a_c on incl (a) include (c);
create index incl_ab on incl (a, b);
create table part (a int, b int);
create index part_a on part (a) where a > 0;
create index part_ab on part (a, b);
create table ops (t text, x int);
create index ops_t on ops (t text_pattern_ops);
create index ops_tx on ops (t, x);
create table coll (t text, x int);
create index coll_t on coll (t collate "C");
create index coll_tx on coll (t collate "POSIX", x);
create table hashes (a int);
create index hash_1 on hashes using hash (a);
create index hash_2 on hashes using hash (a);
create index hash_btree on hashes (a);
create table con (a int, constraint con_uq unique (a));
create unique index con_extra on con (a);
insert into uniq values (1);
insert into pk values (1, 1);
insert into con values (1);
SQL
if (( server_version_num >= 150000 )); then
  "${PSQL[@]}" -qc "create table $SCHEMA.nnd (a int);
    create unique index nnd_plain on $SCHEMA.nnd (a);
    create unique index nnd_strict on $SCHEMA.nnd (a) nulls not distinct;"
fi
sql "analyze" > /dev/null

run_report() { "${PSQL[@]}" -At -F '|' -v postgres_dba_interactive_mode=false -f warmup.psql -f "$1"; }

expected_redundant=$'con:con_extra->con_uq\ncoverage:cov_a->cov_ab\ndup:dup_2->dup_1\nhashes:hash_2->hash_1\nuniq:uniq_plain->uniq_unique'
actual_redundant=$(run_report sql/i2_redundant_indexes.sql \
  | awk -F'|' -v s="$SCHEMA" '$1 == s { gsub(s "\\.", "", $6); print $2 ":" $4 "->" $6 }' | sort)
check "i2 reports exactly the expected redundant indexes" [ "$actual_redundant" == "$expected_redundant" ]
[[ "$actual_redundant" == "$expected_redundant" ]] || printf 'expected:\n%s\nactual:\n%s\n' "$expected_redundant" "$actual_redundant"

expected_duplicates=$'con_uq,con_extra\ndup_1,dup_2\nhash_1,hash_2'
actual_duplicates=$(run_report sql/i3_duplicate_indexes.sql \
  | awk -F'|' -v s="$SCHEMA" 'index($3, s ".") == 1 { gsub(s "\\.", "", $3); gsub(s "\\.", "", $4); print $3 "," $4 }' | sort)
check "i3 groups only fully identical indexes" [ "$actual_duplicates" == "$expected_duplicates" ]
[[ "$actual_duplicates" == "$expected_duplicates" ]] || printf 'expected:\n%s\nactual:\n%s\n' "$expected_duplicates" "$actual_duplicates"

i5_output=$(run_report sql/i5_indexes_migration.sql)
i5_redundant=$(grep "^DROP INDEX CONCURRENTLY $SCHEMA\." <<< "$i5_output" | grep 'redundant to' \
  | sed -E "s/^DROP INDEX CONCURRENTLY $SCHEMA\.([a-z0-9_]+);.*/\1/" | sort | paste -sd, -)
check "i5 suggests dropping only the redundant indexes found by i2" \
  [ "$i5_redundant" == "con_extra,cov_a,dup_2,hash_2,uniq_plain" ]
check "i5 never drops primary keys, constraints or the only unique index" \
  bash -c "! grep -E '^DROP INDEX CONCURRENTLY $SCHEMA\.(pk_pkey|pk_unique_a|uniq_unique|con_uq|nnd_plain|nnd_strict);' <<< \"\$1\"" _ "$i5_output"
check "i5 UNDO recreates unique indexes as unique" \
  grep -q "CREATE UNIQUE INDEX CONCURRENTLY con_extra ON $SCHEMA.con" <<< "$i5_output"

# Apply every DROP suggested for the fixture, then verify that no uniqueness
# guarantee was lost.
# Each statement runs on its own (no ON_ERROR_STOP), so one failing DROP does
# not prevent the others from being applied.
drop_errors=$(grep "^DROP INDEX CONCURRENTLY $SCHEMA\." <<< "$i5_output" \
  | psql --no-psqlrc -q -f - 2>&1 > /dev/null || true)
check "every DROP suggested by i5 can be applied" [ -z "$drop_errors" ]
for statement in "insert into $SCHEMA.uniq values (1)" "insert into $SCHEMA.pk values (1, 2)" "insert into $SCHEMA.con values (1)"; do
  check "uniqueness preserved after applying i5: $statement" \
    bash -c "! psql --no-psqlrc -v ON_ERROR_STOP=1 -qc \"\$1\" > /dev/null 2>&1" _ "$statement"
done

###############################################################################
echo "Role routines (u1, u2)"

password_pattern='^[23456789abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ]{16}$'
stderr_file=$(mktemp)
trap 'rm -f "$stderr_file"; cleanup' EXIT

output=$(printf "postgres_dba_o'test\nnao\nsim\n" \
  | "${PSQL[@]}" -c "set client_min_messages = debug1" -f sql/u1_create_user_with_random_password.sql 2> "$stderr_file" || true)
password=${output##*: }
check "u1 accepts a role name containing an apostrophe" \
  [ "$(sql "select rolsuper::text || rolcanlogin::text || (rolpassword is not null)::text from pg_authid where rolname = 'postgres_dba_o''test'")" == "falsetruetrue" ]
check "u1 generates a 16-character password from the allowed alphabet" bash -c '[[ "$1" =~ $2 ]]' _ "$password" "$password_pattern"
check "u1 never sends the password in a server message" bash -c '! grep -qF -- "$1" "$2"' _ "$password" "$stderr_file"

output=$(printf 'postgres_dba_invalid\nmaybe\nyes\n' | psql --no-psqlrc -f sql/u1_create_user_with_random_password.sql 2>&1)
check "u1 rejects an unknown answer without creating the role" \
  [ -z "$(sql "select 1 from pg_roles where rolname = 'postgres_dba_invalid'")" ]
check "u1 reports that nothing changed" grep -q 'No changes were made' <<< "$output"

sql "create role postgres_dba_alter superuser login" > /dev/null
printf 'postgres_dba_alter\n0\nno\n' | "${PSQL[@]}" -f sql/u2_alter_user_with_random_password.sql > /dev/null 2> "$stderr_file" || true
check "u2 removes SUPERUSER and LOGIN when the answers are no" \
  [ "$(sql "select rolsuper::text || rolcanlogin::text from pg_roles where rolname = 'postgres_dba_alter'")" == "falsefalse" ]
printf 'postgres_dba_alter\nyes\nsim\n' | "${PSQL[@]}" -f sql/u2_alter_user_with_random_password.sql > /dev/null 2> "$stderr_file" || true
check "u2 grants SUPERUSER and LOGIN when the answers are yes" \
  [ "$(sql "select rolsuper::text || rolcanlogin::text from pg_roles where rolname = 'postgres_dba_alter'")" == "truetrue" ]
output=$(printf 'postgres_dba_alter\nnope\nno\n' | psql --no-psqlrc -f sql/u2_alter_user_with_random_password.sql 2>&1)
check "u2 rejects an unknown answer without changing the role" \
  [ "$(sql "select rolsuper::text || rolcanlogin::text from pg_roles where rolname = 'postgres_dba_alter'")" == "truetrue" ]

# A CREATEROLE operator (not superuser) must be able to use u1/u2 on ordinary roles.
sql "create role postgres_dba_operator createrole login; create role postgres_dba_target login" > /dev/null
if (( server_version_num >= 160000 )); then
  sql "grant postgres_dba_target to postgres_dba_operator with admin option" > /dev/null
fi
output=$(printf 'postgres_dba_target
no
no
' \
  | "${PSQL[@]}" -U postgres_dba_operator -f sql/u2_alter_user_with_random_password.sql 2>&1 || true)
check "u2 lets a CREATEROLE operator rotate an ordinary role's password" grep -q 'altered' <<< "$output"
check "u2 run by a CREATEROLE operator applies NOLOGIN" \
  [ "$(sql "select rolsuper::text || rolcanlogin::text from pg_roles where rolname = 'postgres_dba_target'")" == "falsefalse" ]
output=$(printf 'postgres_dba_op_created
no
yes
' \
  | "${PSQL[@]}" -U postgres_dba_operator -f sql/u1_create_user_with_random_password.sql 2>&1 || true)
check "u1 lets a CREATEROLE operator create an ordinary role" \
  [ "$(sql "select rolsuper::text || rolcanlogin::text from pg_roles where rolname = 'postgres_dba_op_created'")" == "falsetrue" ]

# A failing CREATE/ALTER ROLE must not echo the statement (and its password).
output=$(printf 'postgres_dba_target
yes
yes
' \
  | psql --no-psqlrc -U postgres_dba_operator -f sql/u2_alter_user_with_random_password.sql 2>&1)
check "u2 refuses SUPERUSER for a non-superuser operator" \
  [ "$(sql "select rolsuper::text from pg_roles where rolname = 'postgres_dba_target'")" == "false" ]
check "u2 errors do not reveal the generated password" bash -c '! grep -qi "password '"'"'" <<< "$1"' _ "$output"
output=$(printf 'postgres_dba_target
no
no
' | psql --no-psqlrc -f sql/u1_create_user_with_random_password.sql 2>&1)
check "u1 errors do not reveal the generated password" \
  bash -c 'grep -q "already exists" <<< "$1" && ! grep -qi "password '"'"'" <<< "$1"' _ "$output"

seed_password() {
  printf '%s\nno\nno\n' "$1" \
    | "${PSQL[@]}" -c "select setseed(0.125)" -f sql/u1_create_user_with_random_password.sql 2> /dev/null \
    | sed -n 's/.*(shown only once): //p' || true
}
first=$(seed_password postgres_dba_seed1)
second=$(seed_password postgres_dba_seed2)
check "passwords do not depend on setseed()" bash -c '[[ -n "$1" && "$1" != "$2" ]]' _ "$first" "$second"

###############################################################################
echo "Input handling (menu, a2, k1, k2)"

injection="x' as d_step_is_q; create table public.postgres_dba_injection_marker(); select '"
output=$(printf '%s\nq\n' "$injection" | psql --no-psqlrc -f start.psql 2>&1 || true)
check "menu does not execute SQL typed as a menu choice" injection_marker_absent
check "menu treats the input as an unknown option" grep -q 'Unknown option' <<< "$output"

for report in sql/a2_queries_runing_n_seconds.sql sql/k1_cancel_pid.sql sql/k2_terminate_pid.sql; do
  output=$(printf '%s\n' "1); create table public.postgres_dba_injection_marker(); select (1" \
    | "${PSQL[@]}" -f warmup.psql -f "$report" 2>&1 || true)
  check "$report rejects non-numeric input" grep -q 'Invalid' <<< "$output"
  check "$report does not execute SQL typed as input" injection_marker_absent
done

PGAPPNAME=postgres_dba_behavior_sleep psql --no-psqlrc -qc "select pg_sleep(30)" > /dev/null 2>&1 &
sleeper_pid=""
for attempt in {1..40}; do
  sleeper_pid=$(sql "select pid from pg_stat_activity where application_name = 'postgres_dba_behavior_sleep' and state = 'active'")
  [[ -n "$sleeper_pid" ]] && break
  sleep 0.25
done
sleep 1.2

duration=$(run_report sql/a2_queries_runing_n_seconds.sql | awk -F'|' '$5 == "postgres_dba_behavior_sleep" { print $7 }')
check "a2 shows a positive duration ($duration)" bash -c '[[ "$1" =~ ^00:00:0[1-9] ]]' _ "$duration"
output=$(printf '3600\n' | "${PSQL[@]}" -At -F'|' -f warmup.psql -f sql/a2_queries_runing_n_seconds.sql || true)
check "a2 filters by the number of seconds typed" bash -c '! grep -q postgres_dba_behavior_sleep <<< "$1"' _ "$output"

output=$(printf '%s\n' "$sleeper_pid" | "${PSQL[@]}" -At -f sql/k1_cancel_pid.sql || true)
check "k1 cancels a valid PID" grep -qE '(^|: )t$' <<< "$output"
wait || true

###############################################################################
echo "Menu generator (init/generate.sh)"

caller_dir=$(mktemp -d)
echo 'caller start' > "$caller_dir/start.psql"
echo 'caller warmup' > "$caller_dir/warmup.psql"
before=$(cat start.psql warmup.psql | sha256sum)
(cd "$caller_dir" && bash "$ROOT/init/generate.sh" > /dev/null) || fail "generator exits successfully"
check "generator leaves files in the caller's directory untouched" \
  bash -c '[[ "$(cat "$1/start.psql")" == "caller start" && "$(cat "$1/warmup.psql")" == "caller warmup" ]]' _ "$caller_dir"
check "generator is idempotent" [ "$(cat start.psql warmup.psql | sha256sum)" == "$before" ]
check "generator leaves no temporary files" bash -c '! ls -A "$1" | grep -q "^\.\(start\|warmup\)\.psql\."' _ "$ROOT"
rm -rf "$caller_dir"

###############################################################################
if (( failures > 0 )); then
  echo "$failures behaviour test(s) failed"
  exit 1
fi
echo "All behaviour tests passed"
