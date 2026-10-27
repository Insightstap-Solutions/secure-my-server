#!/usr/bin/env bash
# Rotate a Laravel APP_KEY with a grace period (Laravel >= 11 honours APP_PREVIOUS_KEYS for
# encryption AND signed URLs). Never prints a key.
#   MODE=start  : new APP_KEY, old one -> APP_PREVIOUS_KEYS, recreate, prove old cookies still decrypt
#   MODE=finish : (after ~7 days) remove APP_PREVIOUS_KEYS, recreate
# Re-encrypt 'encrypted' cast columns yourself between start and finish (see references/04-secrets.md).
#   ssh host 'MODE=start APP_DIR=/srv/app ENV_FILE=.env COMPOSE_FILE=docker-compose.prod.yml \
#             PROJECT=app-prod APP_C=app-app-prod bash -s' < rotate_laravel_app_key.sh
set -euo pipefail
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
rotate_laravel_app_key.sh   (configured through environment variables, see the header of this file)
  MODE=start|finish APP_DIR ENV_FILE COMPOSE_FILE PROJECT APP_C
  THIS SCRIPT CHANGES THINGS: it backs up and edits ENV_FILE and recreates the app, scheduler and queue
  containers. It never prints a key. Ask the owner before running it on production.
EOF
  exit 0
fi
: "${MODE:?start|finish}" "${APP_DIR:?}" "${ENV_FILE:?}" "${COMPOSE_FILE:?}" "${PROJECT:?}" "${APP_C:?}"
cd "$APP_DIR"; DC=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT")
! pgrep -f "docker[ -]compose .*$PROJECT" >/dev/null || { echo "ABORT: compose busy"; exit 1; }
cp -p "$ENV_FILE" "$ENV_FILE.bak-appkey-$MODE-$(date +%Y%m%d_%H%M%S)"
if [ "$MODE" = start ]; then
  [ "$(grep -c '^APP_PREVIOUS_KEYS=' "$ENV_FILE")" = 0 ] || { echo "ABORT: APP_PREVIOUS_KEYS already set"; exit 1; }
  NEW="base64:$(openssl rand -base64 32)" python3 - "$ENV_FILE" <<'PY'
import os, re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
m = re.search(r"(?m)^APP_KEY=(.*)$", s)
if not m or not m.group(1).startswith("base64:"): sys.exit("ABORT: APP_KEY not found")
s = s[:m.start()] + f"APP_KEY={os.environ['NEW']}\nAPP_PREVIOUS_KEYS={m.group(1)}" + s[m.end():]
with open(p, "r+", encoding="utf-8") as f: f.seek(0); f.write(s); f.truncate()
print("APP_KEY replaced; old key kept in APP_PREVIOUS_KEYS")
PY
else
  python3 - "$ENV_FILE" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s, n = re.subn(r"(?m)^APP_PREVIOUS_KEYS=.*\n?", "", s)
with open(p, "r+", encoding="utf-8") as f: f.seek(0); f.write(s); f.truncate()
print(f"APP_PREVIOUS_KEYS lines removed: {n}")
PY
fi
"${DC[@]}" up -d --no-deps --force-recreate app
for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$APP_C")" = healthy ] && break; sleep 2; done
"${DC[@]}" up -d --no-deps --force-recreate scheduler queue
if [ "$MODE" = start ]; then
  docker exec "$APP_C" php artisan tinker --execute='
    $prev = config("app.previous_keys");
    $old = new Illuminate\Encryption\Encrypter(base64_decode(substr($prev[0], 7)), config("app.cipher"));
    echo "previous keys: ", count($prev), " | old-key value decrypts: ", Crypt::decryptString($old->encryptString("ok")), "\n";' 2>&1 | tail -1
else
  docker exec "$APP_C" php artisan tinker --execute='echo "previous keys: ", count(config("app.previous_keys")), "\n";' 2>&1 | tail -1
fi
