#!/usr/bin/env bash
# sigix 段階 4（任意のキャッシュ連携）の結合テスト:
# 上流バックエンドと sigil-stash-kv モックを立て、ネイティブ sigix を起動してキャッシュ連携を検証する。
# 使い方: tests/e2e_cache.sh <sigix の実行ファイル>
# 前提: bash・curl・python3・coreutils。
set -euo pipefail

BIN="${1:?usage: tests/e2e_cache.sh <sigix executable>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
PIDS=()
PASS=0

cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && { kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; }
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  [ -f "$WORK/server.log" ] && { echo "--- server log ---" >&2; cat "$WORK/server.log" >&2; }
  exit 1
}

ok() {
  PASS=$((PASS + 1))
  echo "ok: $*"
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

mkdir -p "$WORK/www"
echo "root" > "$WORK/www/index.html"

PORIGIN="$(free_port)"
PSTASH="$(free_port)"
PSERVER="$(free_port)"

while [ "$PSTASH" = "$PORIGIN" ]; do PSTASH="$(free_port)"; done

python3 "$HERE/fixtures/cache_backend.py" "$PORIGIN" "$WORK/backend.log" &
PIDS+=($!)
python3 "$HERE/fixtures/stash_kv_mock.py" "$PSTASH" "$WORK/stash.log" &
PIDS+=($!)

for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORIGIN/ping" && break
  sleep 0.1
done

SERVER_PID=""
start_sigix() {
  local config="$1"
  [ -n "$SERVER_PID" ] && { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; }
  PSERVER="$(free_port)"
  printf '%s' "$config" | sed "s/@SERVER@/$PSERVER/g; s/@ORIGIN@/$PORIGIN/g; s/@STASH@/$PSTASH/g" > "$WORK/config.json"
  : > "$WORK/server.log"
  "$BIN" "[--config=$WORK/config.json]" >> "$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  PIDS+=($SERVER_PID)
  BASE="http://127.0.0.1:$PSERVER"
  local i
  for i in $(seq 1 50); do
    if curl -s -o /dev/null --max-time 2 "$BASE/"; then : > "$WORK/server.log"; return 0; fi
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.2
  done
  fail "sigix を起動できなかった"
}

CONFIG_CACHE='{
  "listen": "127.0.0.1:@SERVER@",
  "routes": [
    {
      "prefix": "/api/",
      "type": "proxy",
      "backends": ["127.0.0.1:@ORIGIN@"],
      "cache": {
        "backend": "127.0.0.1:@STASH@",
        "ttl_sec": 60
      }
    },
    {
      "prefix": "/nocache/",
      "type": "proxy",
      "backends": ["127.0.0.1:@ORIGIN@"]
    },
    {
      "prefix": "/",
      "type": "static",
      "root": "'"$WORK"'/www"
    }
  ]
}'

start_sigix "$CONFIG_CACHE"

# 1. キャッシュヒットの確認: 1回目の要求はオリジンへ行き、2回目はキャッシュから返る
body1="$(curl -s "$BASE/api/cacheable")"
[ "$body1" = "cached response count=1" ] || fail "1回目の要求の応答が不正: $body1"

body2="$(curl -s "$BASE/api/cacheable")"
[ "$body2" = "cached response count=1" ] || fail "2回目の要求でキャッシュが使われていない: $body2"

# サーバーログに cache バックエンドが記録されていることを確認
grep -q "GET /api/cacheable HTTP/1.1 200 .* cache" "$WORK/server.log" || fail "アクセスログに cache バックエンドが記録されていない"
ok "キャッシュヒット（同一内容の返却とアクセスログ記録）"

# 2. クエリパラメータで別キーになること
body_q1="$(curl -s "$BASE/api/cacheable?page=1")"
body_q2="$(curl -s "$BASE/api/cacheable?page=2")"
body_q1_repeat="$(curl -s "$BASE/api/cacheable?page=1")"
[ "$body_q1" != "$body_q2" ] || fail "クエリパラメータによるキー分離が効いていない"
[ "$body_q1" = "$body_q1_repeat" ] || fail "クエリパラメータ付き URL のキャッシュヒット失敗"
ok "クエリパラメータによるキー分離とヒット"

# 3. TTL 期限切れでオリジン再取得
# /api/cacheable は max-age=2 なので、2.5 秒待つと期限切れとなりオリジン再取得で count が増える
sleep 2.5
body_expired="$(curl -s "$BASE/api/cacheable")"
[ "$body_expired" != "cached response count=1" ] || fail "TTL 期限切れ後にオリジンから再取得されていない"
ok "TTL 期限切れ後のオリジン再取得"

# 4. 要求側の共有不可条件（通過）
# 4a. Authorization 付き
auth1="$(curl -s -H "Authorization: Bearer test" "$BASE/api/cacheable")"
auth2="$(curl -s -H "Authorization: Bearer test" "$BASE/api/cacheable")"
[ "$auth1" != "$auth2" ] || fail "Authorization 付き要求がオリジンを通過していない"
ok "Authorization 付き要求のキャッシュ通過"

# 4b. Cookie 付き
c1="$(curl -s -b "session=1" "$BASE/api/cacheable")"
c2="$(curl -s -b "session=1" "$BASE/api/cacheable")"
[ "$c1" != "$c2" ] || fail "Cookie 付き要求がオリジンを通過していない"
ok "Cookie 付き要求のキャッシュ通過"

# 4c. Cache-Control: no-store / no-cache
ns1="$(curl -s -H "Cache-Control: no-store" "$BASE/api/cacheable")"
ns2="$(curl -s -H "Cache-Control: no-store" "$BASE/api/cacheable")"
[ "$ns1" != "$ns2" ] || fail "Cache-Control: no-store 要求がオリジンを通過していない"
ok "Cache-Control: no-store 要求のキャッシュ通過"

# 4c-2. P1: 引数付き Cache-Control: no-cache="x-foo"
nc_arg1="$(curl -s -H 'Cache-Control: no-cache="x-foo"' "$BASE/api/cacheable")"
nc_arg2="$(curl -s -H 'Cache-Control: no-cache="x-foo"' "$BASE/api/cacheable")"
[ "$nc_arg1" != "$nc_arg2" ] || fail "Cache-Control: no-cache=\"x-foo\" 要求がオリジンを通過していない"
ok "Cache-Control: no-cache 引数付き要求のキャッシュ通過（P1）"

# 4d. POST メソッド
p1="$(curl -s -X POST "$BASE/api/cacheable")"
p2="$(curl -s -X POST "$BASE/api/cacheable")"
[ "$p1" != "$p2" ] || fail "POST 要求がオリジンを通過していない"
ok "POST 要求のキャッシュ通過"

# 5. 応答側の共有不可条件（オリジンがキャッシュ不可指示を返した場合、次回もオリジンへ行く）
# 5a. private
priv1="$(curl -s "$BASE/api/private")"
priv2="$(curl -s "$BASE/api/private")"
[ "$priv1" != "$priv2" ] || fail "private 応答がキャッシュされてしまった"
ok "private 応答の通過"

# 5a-2. P1: 引数付き private="x-user-info"
pq1="$(curl -s "$BASE/api/private-qual")"
pq2="$(curl -s "$BASE/api/private-qual")"
[ "$pq1" != "$pq2" ] || fail "private=\"x-user-info\" 応答がキャッシュされてしまった"
ok "private=\"x-user-info\" 応答の通過（P1）"

# 5b. no-store
nostore1="$(curl -s "$BASE/api/no-store")"
nostore2="$(curl -s "$BASE/api/no-store")"
[ "$nostore1" != "$nostore2" ] || fail "no-store 応答がキャッシュされてしまった"
ok "no-store 応答の通過"

# 5b-2. P1: 引数付き no-cache="x-user-info"
ncq1="$(curl -s "$BASE/api/no-cache-qual")"
ncq2="$(curl -s "$BASE/api/no-cache-qual")"
[ "$ncq1" != "$ncq2" ] || fail "no-cache=\"x-user-info\" 応答がキャッシュされてしまった"
ok "no-cache=\"x-user-info\" 応答の通過（P1）"

# 5c. Set-Cookie
sc1="$(curl -s "$BASE/api/set-cookie")"
sc2="$(curl -s "$BASE/api/set-cookie")"
[ "$sc1" != "$sc2" ] || fail "Set-Cookie 応答がキャッシュされてしまった"
ok "Set-Cookie 応答の通過"

# 5d. Vary
vary1="$(curl -s "$BASE/api/vary")"
vary2="$(curl -s "$BASE/api/vary")"
[ "$vary1" != "$vary2" ] || fail "Vary 応答がキャッシュされてしまった"
ok "Vary 応答の通過"

# 5e. 404 Not Found
code1="$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/notfound")"
code2="$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/notfound")"
[ "$code1" = "404" ] && [ "$code2" = "404" ] || fail "404 応答の伝播失敗"
ok "404 応答の通過"

# 5f. P2: 既に stale（Age: 15, max-age: 10）な応答の通過
stale1="$(curl -s "$BASE/api/age-stale")"
stale2="$(curl -s "$BASE/api/age-stale")"
[ "$stale1" != "$stale2" ] || fail "stale (Age: 15, max-age: 10) な応答がキャッシュされてしまった"
ok "stale (Age > max-age) 応答の通過（P2）"

# 5g. P2: Age: 2 と max-age: 10（残余鮮度 8 秒）のキャッシュ保存とヒット時の Age ヘッダ更新
act1="$(curl -s "$BASE/api/age-active")"
act2="$(curl -s "$BASE/api/age-active")"
[ "$act1" = "$act2" ] || fail "残余鮮度のある応答がキャッシュヒットしなかった"
age_hdr="$(curl -s -i "$BASE/api/age-active" | grep -i "^age:" | tr -d '\r' | awk '{print $2}')"
[ -n "$age_hdr" ] || fail "キャッシュヒット応答に Age ヘッダが付与されていない"
[ "$age_hdr" -ge 2 ] || fail "キャッシュヒット応答の Age ($age_hdr) が initial_age (2) 以上になっていない"
ok "残余鮮度計算によるキャッシュ保存と Age ヘッダ更新（P2）"

# 6. 上限超過
# 6a. 応答サイズ上限超過（3072 バイト超）: クライアントへは正常に届くがキャッシュされない
big1_len="$(curl -s "$BASE/api/big" | wc -c)"
[ "$big1_len" -ge 3500 ] || fail "大きな応答の受信長が不正: $big1_len"
big2_len="$(curl -s "$BASE/api/big" | wc -c)"
[ "$big2_len" -ge 3500 ] || fail "大きな応答の再受信失敗: $big2_len"
ok "3072 バイト超過応答の通過（キャッシュ非保存）"

# 6b. キー長上限超過（512 バイト超）
long_path="$(python3 -c 'print("x" * 600)')"
lp_code="$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/$long_path")"
[ "$lp_code" = "200" ] || fail "長いキーの要求がオリジンで 200 にならなかった"
ok "512 バイト超過キーの通過"

# 7. KV 障害時のフォールバック（オリジン利用継続）
# stash-kv プロセスを終了させても、sigix はエラーにならずオリジンから正常応答する
stash_pid="${PIDS[1]}"
kill -9 "$stash_pid" 2>/dev/null || true
wait "$stash_pid" 2>/dev/null || true

fallback_res="$(curl -s "$BASE/api/cacheable")"
[ -n "$fallback_res" ] || fail "stash-kv 停止時に応答が空"
[[ "$fallback_res" =~ "cached response count=" ]] || fail "stash-kv 停止時にオリジンから取得できなかった: $fallback_res"
ok "KV 障害時のフォールバック（オリジン利用継続）"

echo "=== All $PASS cache E2E tests passed! ==="
