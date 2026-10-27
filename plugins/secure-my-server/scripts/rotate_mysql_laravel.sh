#!/usr/bin/env bash
# Rotate a Laravel env's MySQL app-user and root passwords. Never prints a secret.
# Run on the server as the env file's owner:
#   ssh host 'APP_DIR=/srv/app ENV_FILE=.env COMPOSE_FILE=docker-compose.prod.yml PROJECT=app-prod \
#             MYSQL_C=app-mysql-prod APP_C=app-app-prod bash -s' < rotate_mysql_laravel.sh
# Services are assumed to be named mysql / app / scheduler / queue in compose. Ask the user first on prod.
set -euo pipefail
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
rotate_mysql_laravel.sh   (configured through environment variables, see the header of this file)
  APP_DIR ENV_FILE COMPOSE_FILE PROJECT MYSQL_C APP_C
  THIS SCRIPT CHANGES THINGS: it backs up and edits ENV_FILE, changes the MySQL app-user and root
  passwords, and recreates the mysql, app, scheduler and queue containers. It never prints a secret.
  Ask the owner before running it on production.
EOF
  exit 0
fi
: "${APP_DIR:?}" "${ENV_FILE:?}" "${COMPOSE_FILE:?}" "${PROJECT:?}" "${MYSQL_C:?}" "${APP_C:?}"
cd "$APP_DIR"
DC=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT")
getv() { sed '1s/^\xEF\xBB\xBF//' "$ENV_FILE" | tr -d '\r' | grep -E "^$1=" | head -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'; }
OLD_ROOT=$(getv DB_ROOT_PASSWORD); DBU=$(getv DB_USERNAME)
docker exec -e MYSQL_PWD="$OLD_ROOT" "$MYSQL_C" mysql -uroot -N -e 'select 1' >/dev/null 2>&1 || { echo "ABORT: root password in $ENV_FILE does not open $MYSQL_C"; exit 1; }
! pgrep -f "docker[ -]compose .*$PROJECT" >/dev/null || { echo "ABORT: another compose run on $PROJECT is in progress"; exit 1; }
TS=$(date +%Y%m%d_%H%M%S); cp -p "$ENV_FILE" "$ENV_FILE.bak-rotate-$TS"; chmod 600 "$ENV_FILE.bak-rotate-$TS"
echo "backup: $APP_DIR/$ENV_FILE.bak-rotate-$TS"
SUM=$(md5sum < "$ENV_FILE"); NEW_ROOT=$(openssl rand -hex 24); NEW_APP=$(openssl rand -hex 24)
SUM="$SUM" NEW_ROOT="$NEW_ROOT" NEW_APP="$NEW_APP" python3 - "$ENV_FILE" <<'PY'
import hashlib, os, re, sys
p = sys.argv[1]; raw = open(p, "rb").read()
if hashlib.md5(raw).hexdigest() + "  -" != os.environ["SUM"].strip(): sys.exit("ABORT: env file changed under us")
s = raw.decode("utf-8")
for k, v in (("DB_PASSWORD", os.environ["NEW_APP"]), ("DB_ROOT_PASSWORD", os.environ["NEW_ROOT"])):
    s, n = re.subn(rf"(?m)^{k}=.*$", lambda m: f"{k}={v}", s)
    if n != 1: sys.exit(f"ABORT: {k} matched {n} lines")
with open(p, "r+", encoding="utf-8") as f: f.seek(0); f.write(s); f.truncate()   # same inode (bind mount)
print("env file updated in place")
PY
printf "ALTER USER IF EXISTS '%s'@'%%' IDENTIFIED BY '%s';\nALTER USER IF EXISTS 'root'@'%%' IDENTIFIED BY '%s';\nALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED BY '%s';\nFLUSH PRIVILEGES;\n" \
  "$DBU" "$NEW_APP" "$NEW_ROOT" "$NEW_ROOT" | docker exec -i -e MYSQL_PWD="$OLD_ROOT" "$MYSQL_C" mysql -uroot 2>&1 | grep -v Warning || true
"${DC[@]}" up -d --no-deps mysql                      # its healthcheck has the root password baked in
for _ in $(seq 1 45); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$MYSQL_C")" = healthy ] && break; sleep 2; done
"${DC[@]}" up -d --no-deps --force-recreate app       # RECREATE, never restart (stale config cache)
for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$APP_C")" = healthy ] && break; sleep 2; done
"${DC[@]}" up -d --no-deps --force-recreate scheduler
nohup "${DC[@]}" up -d --no-deps --force-recreate queue >"/tmp/queue-recreate-$PROJECT.log" 2>&1 &
echo "--- verify"
echo "app connects as: $(docker exec "$APP_C" php artisan tinker --execute='echo DB::select("select current_user() u")[0]->u;' 2>&1 | tail -1)"
echo "old root refused: $(docker exec -e MYSQL_PWD="$OLD_ROOT" "$MYSQL_C" mysql -uroot -N -e 'select 1' 2>&1 | grep -c 'Access denied')"
echo "new root works:   $(docker exec -e MYSQL_PWD="$NEW_ROOT" "$MYSQL_C" mysql -uroot -N -e 'select 1' 2>&1 | grep -v Warning)"
unset OLD_ROOT NEW_ROOT NEW_APP
