#!/usr/bin/env bash
# sigix 段階 2（リバースプロキシ）の結合テスト: 上流を Python で 2 台立て、ネイティブの sigix を起動して curl で確かめる。
# 使い方: tests/e2e_proxy.sh <sigix の実行ファイル>
# 前提: bash・curl・python3・coreutils。
set -euo pipefail

BIN="${1:?usage: tests/e2e_proxy.sh <sigix executable>}"
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

fail() { echo "FAIL: $*" >&2; [ -f "$WORK/server.log" ] && { echo "--- server log ---" >&2; cat "$WORK/server.log" >&2; }; exit 1; }
ok() { PASS=$((PASS + 1)); echo "ok: $*"; }

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# 公開ルート（静的）
mkdir -p "$WORK/www" "$WORK/static"
echo "root-index" > "$WORK/www/index.html"
echo "body{}" > "$WORK/static/a.css"

PA="$(free_port)"; PB="$(free_port)"; PDEAD="$(free_port)"; PSERVER="$(free_port)"
while [ "$PB" = "$PA" ]; do PB="$(free_port)"; done

python3 "$HERE/fixtures/backend.py" "$PA" A & PIDS+=($!)
python3 "$HERE/fixtures/backend.py" "$PB" B & PIDS+=($!)
for p in "$PA" "$PB"; do
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$p/ping" && break; sleep 0.1; done
done

SERVER_PID=""
start_sigix() { # 引数: 設定ファイルの本文（JSON）
  [ -n "$SERVER_PID" ] && { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; }
  PSERVER="$(free_port)"
  printf '%s' "$1" | sed "s/@SERVER@/$PSERVER/g" > "$WORK/config.json"
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

py() { python3 -c "$@"; }
# JSON の応答（echo）から値を取り出す。 jq 的な使い方: jfield '<JSON>' 'expr(d)'
jfield() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$2"; }
jfile() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

CONFIG_BASE='{"listen":"127.0.0.1:@SERVER@","connect_timeout_ms":1000,"read_timeout_ms":1500,"routes":[
 {"prefix":"/api/","type":"proxy","backends":["127.0.0.1:'"$PA"'","127.0.0.1:'"$PB"'"]},
 {"prefix":"/static/","type":"static","root":"'"$WORK"'/static"},
 {"prefix":"/","type":"static","root":"'"$WORK"'/www"}]}'

start_sigix "$CONFIG_BASE"

# 1. ラウンドロビン（A, B, A, B, A, B）
seq_out=""
for _ in 1 2 3 4 5 6; do
  r="$(curl -s "$BASE/api/rr")"
  seq_out="$seq_out$(jfield "$r" 'd["backend"]')"
done
[ "$seq_out" = "ABABAB" ] || { [ "$seq_out" = "BABABA" ] || fail "ラウンドロビン: $seq_out"; }
ok "ラウンドロビン（$seq_out）"

# 2. ヘッダ: 偽装・ホップバイホップが上流に届かず、X-Forwarded-Proto が付く
r="$(curl -s -H 'X-Forwarded-For: 6.6.6.6' -H 'Forwarded: for=6.6.6.6' -H 'X-Real-IP: 6.6.6.6' -H 'X-Forwarded-Proto: https' \
  -H 'Connection: keep-alive, X-Secret' -H 'X-Secret: s' -H 'Keep-Alive: timeout=9' -H 'TE: trailers' -H 'Upgrade: foo' -H 'X-Keep: yes' "$BASE/api/h")"
[ "$(jfield "$r" 'd["headers"].get("x-forwarded-proto")')" = "http" ] || fail "X-Forwarded-Proto が http でない: $r"
for h in forwarded x-real-ip x-secret keep-alive te upgrade transfer-encoding; do
  [ "$(jfield "$r" "'$h' in d['headers']")" = "False" ] || fail "$h が上流へ届いた: $r"
done
[ "$(jfield "$r" '"6.6.6.6" in json.dumps(d["headers"])')" = "False" ] || fail "偽装した接続元が上流へ届いた: $r"
[ "$(jfield "$r" 'd["headers"].get("x-keep")')" = "yes" ] || fail "通常のヘッダが届かない: $r"
[ "$(jfield "$r" 'd["headers"].get("connection")')" = "close" ] || fail "Connection: close を付ける: $r"
ok "ヘッダの書き換え（偽装の破棄・ホップバイホップの剥離・X-Forwarded-Proto: http）"

# 経路・クエリはそのまま
[ "$(jfield "$r" 'd["path"]')" = "/api/h" ] || fail "経路: $r"
r="$(curl -s "$BASE/api/q?a=1&b=%20x")"
[ "$(jfield "$r" 'd["path"]')" = "/api/q?a=1&b=%20x" ] || fail "クエリを保つ: $r"
ok "経路とクエリは接頭辞を含めてそのまま上流へ渡す"

# 応答側のホップバイホップの剥離
hdrs="$(curl -si "$BASE/api/hopbyhop")"
echo "$hdrs" | grep -qi '^x-drop-me:' && fail "応答の Connection 名指しのヘッダが残った"
echo "$hdrs" | grep -qi '^keep-alive:' && fail "応答の Keep-Alive が残った"
echo "$hdrs" | grep -qi '^x-backend:' || fail "応答の通常ヘッダが消えた"
ok "応答のホップバイホップを剥がす"

# 3. Host: 既定は保つ
r="$(curl -s -H 'Host: front.example' "$BASE/api/host")"
[ "$(jfield "$r" 'd["headers"]["host"]')" = "front.example" ] || fail "Host を保つ: $r"
ok "Host を保つ（既定）"

# 4. POST / PUT の本文（バイナリ・大きめの本文を含む）
head -c 300000 /dev/urandom > "$WORK/blob"
od -An -v -tx1 "$WORK/blob" | tr -d ' \n' > "$WORK/resp.json.hex"
for m in POST PUT; do
  curl -s -X "$m" --data-binary "@$WORK/blob" -H 'Content-Type: application/octet-stream' -o "$WORK/resp.json" "$BASE/api/body"
  [ "$(jfile "$WORK/resp.json" 'd["method"]')" = "$m" ] || fail "$m: メソッド"
  [ "$(jfile "$WORK/resp.json" 'd["body_hex"] == open(sys.argv[1] + ".hex").read().strip()' )" = "True" ] || fail "$m: 本文が一致しない"
  [ "$(jfile "$WORK/resp.json" 'd["headers"]["content-length"]')" = "300000" ] || fail "$m: Content-Length"
done
ok "POST / PUT の本文（300000 バイトのバイナリ）が往復する"

# チャンクの応答・上流のエラー状態・HEAD
[ "$(curl -s "$BASE/api/chunked")" = "hello chunked world" ] || fail "チャンクの応答"
[ "$(curl -s "$BASE/api/tinychunks" | wc -c)" = "200000" ] || fail "1 バイトずつのチャンク（枠が本文の 6 倍）で 502 になった"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/notfound")" = "404" ] || fail "上流の 404 を中継する"
[ "$(curl -s -o /dev/null -w '%{http_code}' -I "$BASE/api/head")" = "200" ] || fail "HEAD"
ok "チャンクの応答・上流の状態（404）・HEAD"

# 6. 静的配信との併用
[ "$(curl -s "$BASE/")" = "root-index" ] || fail "静的配信 /"
[ "$(curl -s "$BASE/static/a.css")" = "body{}" ] || fail "静的配信 /static/"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/static/missing")" = "404" ] || fail "静的の 404"
[ "$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "$BASE/static/../www/index.html")" = "400" ] || fail "静的の .. は 400"
ok "静的配信とプロキシの併用"

# 8. 条件付き GET
hdrs="$(curl -si "$BASE/static/a.css")"
etag="$(echo "$hdrs" | grep -i '^etag:' | tr -d '\r' | cut -d' ' -f2)"
lm="$(echo "$hdrs" | grep -i '^last-modified:' | tr -d '\r' | cut -d' ' -f2-)"
[ -n "$etag" ] && [ -n "$lm" ] || fail "ETag / Last-Modified が無い: $hdrs"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "If-None-Match: $etag" "$BASE/static/a.css")" = "304" ] || fail "If-None-Match で 304 にならない"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "If-Modified-Since: $lm" "$BASE/static/a.css")" = "304" ] || fail "If-Modified-Since で 304 にならない"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'If-None-Match: "other"' "$BASE/static/a.css")" = "200" ] || fail "不一致は 200"
[ "$(curl -s -H "If-None-Match: $etag" "$BASE/static/a.css" | wc -c)" = "0" ] || fail "304 に本文がある"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'If-Modified-Since: Thu, 01 Jan 1970 00:00:00 GMT' "$BASE/static/a.css")" = "200" ] || fail "古い日付は 200"
ok "条件付き GET（ETag / Last-Modified / 304）"

# 7. ログ
sleep 0.3
grep -Eq "^[0-9]+ GET /api/rr HTTP/1\.1 200 [0-9]+ 127\.0\.0\.1:($PA|$PB) 200$" "$WORK/server.log" || fail "プロキシのアクセスログの形式"
grep -Eq '^[0-9]+ GET /static/a\.css HTTP/1\.1 304 0$' "$WORK/server.log" || fail "静的の 304 のログ"
grep -Eq '^[0-9]+ GET /static/a\.css HTTP/1\.1 200 7$' "$WORK/server.log" || fail "静的のログ（段階 1 の形式）"
ok "アクセスログ（転送先と上流の状態）"

# 5. 502: 上流が落ちている / 応答しない
DEAD_CONFIG='{"listen":"127.0.0.1:@SERVER@","connect_timeout_ms":1000,"read_timeout_ms":1000,"routes":[
 {"prefix":"/api/","type":"proxy","backends":["127.0.0.1:'"$PDEAD"'"]},
 {"prefix":"/","type":"static","root":"'"$WORK"'/www"}]}'
start_sigix "$DEAD_CONFIG"
t0=$(date +%s.%N)
code="$(curl -s -o "$WORK/502.body" -w '%{http_code}' --max-time 10 "$BASE/api/x")"
t1=$(date +%s.%N)
[ "$code" = "502" ] || fail "落ちている上流は 502（実際 $code）"
[ "$(cat "$WORK/502.body")" = "Bad Gateway" ] || fail "502 の本文は固定"
py 'import sys; sys.exit(0 if float(sys.argv[2])-float(sys.argv[1]) < 3.0 else 1)' "$t0" "$t1" || fail "502 が遅い"
sleep 0.2
grep -Eq "^[0-9]+ GET /api/x HTTP/1\.1 502 12 127\.0\.0\.1:$PDEAD -$" "$WORK/server.log" || fail "502 のログ"
[ "$(curl -s "$BASE/")" = "root-index" ] || fail "上流が落ちていても静的配信は続く"
ok "上流が落ちていれば 502（固定本文・ログに - ）"

HANG_CONFIG='{"listen":"127.0.0.1:@SERVER@","connect_timeout_ms":1000,"read_timeout_ms":1000,"routes":[
 {"prefix":"/api/","type":"proxy","backends":["127.0.0.1:'"$PA"'"]},
 {"prefix":"/","type":"static","root":"'"$WORK"'/www"}]}'
start_sigix "$HANG_CONFIG"
t0=$(date +%s.%N)
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/api/hang")"
t1=$(date +%s.%N)
[ "$code" = "502" ] || fail "応答しない上流は 502（実際 $code）"
py 'import sys; d=float(sys.argv[2])-float(sys.argv[1]); sys.exit(0 if 0.8 < d < 4.0 else 1)' "$t0" "$t1" || fail "時間切れの長さが想定外"
ok "応答しない上流はタイムアウトで 502"

# 3'. Host を転送先へ書き換える設定
HOST_CONFIG='{"listen":"127.0.0.1:@SERVER@","routes":[
 {"prefix":"/api/","type":"proxy","host":"backend","backends":["127.0.0.1:'"$PA"'"]},
 {"prefix":"/","type":"static","root":"'"$WORK"'/www"}]}'
start_sigix "$HOST_CONFIG"
r="$(curl -s -H 'Host: front.example' "$BASE/api/host")"
[ "$(jfield "$r" 'd["headers"]["host"]')" = "127.0.0.1:$PA" ] || fail "Host を転送先へ書き換える: $r"
ok "Host を転送先へ書き換える（host: backend）"

# 設定の拒否（fail-closed）: 待ち受けない
BAD_PORT="$(free_port)"
for bad in '{"routes":[{"prefix":"/","type":"static","root":"/x"}],"unknown":1}' \
           '{"routes":[{"prefix":"/api/","type":"proxy","backends":["localhost:80"]}]}' \
           '{"connect_timeout_ms":0,"routes":[{"prefix":"/","type":"static","root":"/x"}]}' \
           '{"routes":[{"prefix":"/","type":"static","root":"/nonexistent-sigix-root"}],"listen":"127.0.0.1:'"$BAD_PORT"'"}' \
           'not json'; do
  printf '%s' "$bad" > "$WORK/bad.json"
  out="$("$BIN" "[--config=$WORK/bad.json,--listen=127.0.0.1:$BAD_PORT]" 2>&1 | tail -n 2 | tr '\n' ' ')"
  case "$out" in *"sigix:"*) ;; *) fail "不正な設定を拒否しない: $bad -> $out";; esac
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$BAD_PORT/" && fail "不正な設定でも待ち受けた: $bad"
done
ok "不正な設定は起動時に拒否する（待ち受けない）"

echo "e2e (proxy): $PASS 件すべて成功"
