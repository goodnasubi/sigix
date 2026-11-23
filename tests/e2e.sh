#!/usr/bin/env bash
# sigix 段階 1 の結合テスト: ネイティブの実行ファイルを実際に起動し、curl で HTTP を話しかける。
# 使い方: tests/e2e.sh <sigix の実行ファイル>
# 前提: bash・curl・coreutils。リポジトリの直下から（または test.sh から）呼ぶ。
set -euo pipefail

BIN="${1:?usage: tests/e2e.sh <sigix executable>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
SERVER_PID=""
PASS=0

cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; [ -f "$WORK/server.log" ] && { echo "--- server log ---" >&2; cat "$WORK/server.log" >&2; }; exit 1; }
ok() { PASS=$((PASS + 1)); echo "ok: $*"; }

# 公開ルート: tests/fixtures/www（相対 symlink つき）と、ルート外のファイルを、そのまま作業領域へ写す。
cp -a "$HERE/fixtures" "$WORK/fixtures"
WWW="$WORK/fixtures/www"
# 上限の検査用の大きなファイル（疎なファイルで足りるが、読み出しは全バイト 0 として行われる）。
head -c 1048576 /dev/zero > "$WWW/m1.bin"
head -c 1048577 /dev/zero > "$WWW/m1p1.bin"
head -c 2097152 /dev/zero > "$WWW/m2.bin"
head -c 2097153 /dev/zero > "$WWW/m2p1.bin"
head -c 67108864 /dev/zero > "$WWW/m64.bin"

start_server() { # 引数: 追加のオプション（`--max-response-body=...` など）
  local extra="$1"
  local attempt
  for attempt in 1 2 3 4 5; do
    PORT=$((20000 + RANDOM % 20000))
    : > "$WORK/server.log"
    "$BIN" "[--listen,127.0.0.1:$PORT,--root=$WWW${extra:+,$extra}]" >> "$WORK/server.log" 2>&1 &
    SERVER_PID=$!
    local i
    for i in $(seq 1 50); do
      if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/a.txt"; then
        BASE="http://127.0.0.1:$PORT"
        : > "$WORK/server.log"
        return 0
      fi
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
  done
  fail "サーバーを起動できなかった"
}

stop_server() {
  kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
}

# 状態コードだけを返す。--path-as-is で curl が `..` を畳まないようにする。
code() { curl -s -o /dev/null --max-time 120 --path-as-is -w '%{http_code}' "$@"; }

expect_code() { # 期待コード 説明 curl の引数...
  local want="$1" what="$2"; shift 2
  local got
  got="$(code "$@")"
  [ "$got" = "$want" ] || fail "$what: 状態 $got（期待 $want）"
  ok "$what -> $want"
}

# ---------------------------------------------------------------------------
echo "=== 1. GET・HEAD・メソッド（受け入れ条件 1）"
start_server ""

H="$(curl -s -D - -o "$WORK/body" "$BASE/a.txt")"
echo "$H" | head -1 | grep -q '^HTTP/1.1 200' || fail "GET /a.txt の状態"
echo "$H" | grep -qi '^content-type: text/plain; charset=utf-8' || fail "GET /a.txt の Content-Type"
echo "$H" | grep -qi '^content-length: 6' || fail "GET /a.txt の Content-Length"
[ "$(cat "$WORK/body")" = "hello" ] || fail "GET /a.txt の本文"
ok "GET /a.txt は 200・本文・Content-Type・Content-Length"

HH="$(curl -s -I "$BASE/a.txt")"
echo "$HH" | head -1 | grep -q '^HTTP/1.1 200' || fail "HEAD /a.txt の状態"
echo "$HH" | grep -qi '^content-type: text/plain; charset=utf-8' || fail "HEAD の Content-Type"
echo "$HH" | grep -qi '^content-length: 6' || fail "HEAD の Content-Length（GET と同じ値）"
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
printf 'HEAD /a.txt HTTP/1.1\r\nHost: sigix.test\r\nConnection: close\r\n\r\n' >&3
RAW="$(cat <&3)"; exec 3>&-
AFTER="$(printf '%s' "$RAW" | tr -d '\r' | sed '1,/^$/d')"
[ -z "$AFTER" ] || fail "HEAD の応答に本文がある: $AFTER"
ok "HEAD は本文なしで GET と同じヘッダ"

for m in POST PUT DELETE PATCH OPTIONS; do
  R="$(curl -s -i -X "$m" --max-time 5 -d x "$BASE/a.txt")" || fail "$m の送信"
  echo "$R" | head -1 | grep -q '^HTTP/1.1 405' || fail "$m は 405 のはず"
  echo "$R" | grep -qi '^allow: GET, HEAD' || fail "$m の 405 に Allow: GET, HEAD が無い"
done
ok "POST・PUT・DELETE・PATCH・OPTIONS は 405 と Allow: GET, HEAD"

# MIME
mime() { curl -s -o /dev/null -w '%{content_type}' "$BASE$1"; }
[ "$(mime /index.html)" = "text/html; charset=utf-8" ] || fail "MIME html"
[ "$(mime /STYLE.CSS)" = "text/css; charset=utf-8" ] || fail "MIME css（大文字拡張子）"
[ "$(mime /nested/deep/file.json)" = "application/json" ] || fail "MIME json"
[ "$(mime /data.xyz)" = "application/octet-stream" ] || fail "MIME 未知"
[ "$(mime /noext)" = "application/octet-stream" ] || fail "MIME 拡張子なし"
ok "拡張子の表による Content-Type（未知は application/octet-stream）"

# ---------------------------------------------------------------------------
echo "=== 2. 404・ディレクトリ・末尾スラッシュ（受け入れ条件 2）"
expect_code 404 "存在しないファイル" "$BASE/missing.txt"
expect_code 200 "/ は index.html" "$BASE/"
expect_code 200 "/docs/ は index.html" "$BASE/docs/"
expect_code 404 "index.html の無いディレクトリは 403 でなく 404" "$BASE/empty/"
expect_code 404 "存在しないディレクトリ" "$BASE/missing/"
expect_code 404 "通常ファイルへの末尾スラッシュ" "$BASE/a.txt/"
expect_code 301 "末尾スラッシュ無しのディレクトリ" "$BASE/docs"
LOC="$(curl -s -D - -o /dev/null "$BASE/docs" | tr -d '\r' | grep -i '^location:' | sed 's/^[Ll]ocation: //')"
[ "$LOC" = "/docs/" ] || fail "Location は /docs/ のはず（実際: $LOC）"
ok "301 の Location は /docs/"
[ "$(curl -s "$BASE/docs/")" = "docs index" ] || fail "/docs/ の本文"
[ "$(curl -s "$BASE/")" = "$(curl -s "$BASE/index.html")" ] || fail "/ と /index.html の本文"
ok "ディレクトリ要求の本文は index.html"

# ---------------------------------------------------------------------------
echo "=== 3. 公開ルートからの脱出（受け入れ条件 3）"
escape() { # 説明 パス（curl の URL の後ろ）
  local what="$1" path="$2" got
  got="$(curl -s -o "$WORK/esc.body" --max-time 10 --path-as-is -w '%{http_code}' "$BASE$path")"
  case "$got" in 400|404) ;; *) fail "$what: 状態 $got（400 か 404 のはず）";; esac
  if grep -q 'OUTSIDE' "$WORK/esc.body"; then fail "$what: ルート外の内容が返った"; fi
  ok "$what -> $got"
}
escape "dot dot" "/../outside.txt"
escape "深い dot dot" "/docs/../../outside.txt"
escape "%2e%2e" "/%2e%2e/outside.txt"
escape "%2E%2E" "/%2E%2E/outside.txt"
escape ".%2e" "/.%2e/outside.txt"
escape "符号化されたスラッシュ（小文字）" "/docs/..%2foutside.txt"
escape "符号化されたスラッシュ（大文字）" "/docs/..%2Foutside.txt"
escape "符号化された逆スラッシュ" "/docs/..%5coutside.txt"
escape "ヌル文字" "/a.txt%00.png"
escape "改行" "/a.txt%0d%0aX-Injected:1"
escape "二重スラッシュ" "//outside.txt"
escape "ドットの区間" "/docs/./../outside.txt"
escape "ルート外へのシンボリックリンク（ファイル）" "/link_out"
escape "ルート外へのシンボリックリンク（ディレクトリ越し）" "/link_dir/secret.txt"
escape "ルート外へのシンボリックリンク（ディレクトリの index）" "/link_dir/"
escape "ルート内へのシンボリックリンクも追従しない" "/link_in"
if curl -s -i --max-time 5 --path-as-is "$BASE/docs/..%0d%0aX-Injected:1" | grep -qi '^x-injected'; then fail "応答ヘッダへの注入"; fi
ok "ヘッダ注入なし"

# ---------------------------------------------------------------------------
echo "=== 4. 応答本文の上限（受け入れ条件 4）: 既定 1 MiB"
expect_code 200 "ちょうど 1 MiB は配信できる" "$BASE/m1.bin"
[ "$(curl -s -o /dev/null -w '%{size_download}' "$BASE/m1.bin")" = "1048576" ] || fail "1 MiB の本文の大きさ"
R="$(curl -s -i "$BASE/m1p1.bin")"
echo "$R" | head -1 | grep -q '^HTTP/1.1 500' || fail "1 MiB + 1 は 500 のはず"
BODY="$(echo "$R" | tr -d '\r' | sed '1,/^$/d')"
[ "$BODY" = "Internal Server Error" ] || fail "500 の本文は定型のはず（実際: $BODY）"
echo "$R" | grep -q "$WWW" && fail "500 に内部パスが含まれる"
echo "$R" | grep -q '1048577' && fail "500 に実サイズが含まれる"
ok "1 MiB + 1 は 500（定型本文、パス・サイズなし）"
stop_server

echo "=== 4b. 引き上げ時: --max-response-body=2097152 と 67108864（64 MiB）"
start_server "--max-response-body=2097152"
expect_code 200 "ちょうど 2 MiB は配信できる" "$BASE/m2.bin"
expect_code 500 "2 MiB + 1 は 500" "$BASE/m2p1.bin"
stop_server
start_server "--max-response-body=67108864"
expect_code 200 "ちょうど 64 MiB は配信できる" "$BASE/m64.bin"
[ "$(curl -s -o /dev/null --max-time 120 -w '%{size_download}' "$BASE/m64.bin")" = "67108864" ] || fail "64 MiB の本文の大きさ"
ok "64 MiB の本文が欠けずに届く"
stop_server

# ---------------------------------------------------------------------------
echo "=== 5. 設定の不正値は起動時に拒否（受け入れ条件 5）"
expect_fail() { # 説明 引数（一覧）［環境変数 NAME=VALUE...］
  local what="$1" args="$2"; shift 2
  local out
  out="$(env "$@" timeout 10 "$BIN" "$args" 2>&1)" || true
  echo "$out" | grep -q '^sigix: ' || fail "$what: エラーメッセージが出ない（出力: $out）"
  [ "$(echo "$out" | tail -1)" = "2" ] || [ "$(echo "$out" | tail -1)" = "3" ] || fail "$what: 起動を中止していない（出力: $out）"
  ok "$what は起動時に拒否"
}
expect_fail "root なし" "[]"
expect_fail "存在しない root" "[--root=$WORK/none]"
expect_fail "root がファイル" "[--root=$WWW/a.txt]"
expect_fail "不正な listen" "[--root=$WWW,--listen=bad]"
expect_fail "ポート 0" "[--root=$WWW,--listen=127.0.0.1:0]"
expect_fail "ポート範囲外" "[--root=$WWW,--listen=127.0.0.1:65536]"
expect_fail "上限 0" "[--root=$WWW,--max-response-body=0]"
expect_fail "上限が 64 MiB 超" "[--root=$WWW,--max-response-body=67108865]"
expect_fail "上限が数値でない" "[--root=$WWW,--max-response-body=abc]"
expect_fail "未知のオプション" "[--root=$WWW,--bogus=1]"
expect_fail "位置引数" "[--root=$WWW,extra]"
expect_fail "重複したオプション" "[--root=$WWW,--root=$WWW]"
expect_fail "値の欠落" "[--root=$WWW,--listen]"
expect_fail "環境変数の不正な listen" "[--root=$WWW]" SIGIX_LISTEN=nope
expect_fail "環境変数の不正な上限" "[--root=$WWW]" SIGIX_MAX_RESPONSE_BODY=-5
expect_fail "環境変数の存在しない root" "[]" SIGIX_ROOT="$WORK/none"
# 使用中のポートでの待ち受け失敗
start_server ""
USED_PORT="$PORT"
out="$(timeout 10 "$BIN" "[--root=$WWW,--listen=127.0.0.1:$USED_PORT]" 2>&1)" || true
echo "$out" | grep -q '^sigix: ' || fail "使用中のポート: エラーメッセージが出ない"
ok "使用中のポートでは待ち受けずに終わる"
stop_server

# 環境変数だけで起動でき、起動引数が環境変数に勝つ
PORT=$((20000 + RANDOM % 20000))
SIGIX_ROOT="$WWW" SIGIX_LISTEN="127.0.0.1:$PORT" "$BIN" "[]" >> "$WORK/server.log" 2>&1 &
SERVER_PID=$!
for i in $(seq 1 50); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/a.txt" && break; sleep 0.2; done
[ "$(curl -s "http://127.0.0.1:$PORT/a.txt")" = "hello" ] || fail "環境変数だけでの起動"
ok "環境変数 SIGIX_ROOT・SIGIX_LISTEN だけで起動できる"
stop_server

# ---------------------------------------------------------------------------
echo "=== 6. アクセスログ（受け入れ条件 6）"
start_server ""
curl -s -o /dev/null "$BASE/a.txt"
curl -s -o /dev/null -I "$BASE/a.txt"
curl -s -o /dev/null "$BASE/nope"
curl -s -o /dev/null -X POST "$BASE/a.txt"
curl -s -o /dev/null --path-as-is "$BASE/../x"
curl -s -o /dev/null "$BASE/docs"
sleep 0.5
LOG="$WORK/server.log"
[ "$(wc -l < "$LOG")" -eq 6 ] || fail "ログの行数が 6 でない: $(wc -l < "$LOG")"
grep -Eqv '^[0-9]+ [A-Z]+ [!-~]+ HTTP/1\.[01] [0-9]{3} [0-9]+$' "$LOG" && fail "ログの形式が違う行がある"
grep -Eq '^[0-9]+ GET /a\.txt HTTP/1\.1 200 6$' "$LOG" || fail "GET のログ"
grep -Eq '^[0-9]+ HEAD /a\.txt HTTP/1\.1 200 0$' "$LOG" || fail "HEAD のログ"
grep -Eq '^[0-9]+ GET /nope HTTP/1\.1 404 10$' "$LOG" || fail "404 のログ"
grep -Eq '^[0-9]+ POST /a\.txt HTTP/1\.1 405 19$' "$LOG" || fail "405 のログ"
grep -Eq '^[0-9]+ GET /\.\./x HTTP/1\.1 400 12$' "$LOG" || fail "400 のログ"
grep -Eq '^[0-9]+ GET /docs HTTP/1\.1 301 18$' "$LOG" || fail "301 のログ"
NOW="$(date +%s)"; T="$(head -1 "$LOG" | cut -d' ' -f1)"
[ $((NOW - T)) -lt 30 ] && [ $((T - NOW)) -lt 30 ] || fail "ログの時刻が現在から離れている（$T と $NOW）"
ok "ログは「時刻 メソッド 経路 HTTP版 状態 バイト数」の 1 行 1 要求"
stop_server

echo "全 $PASS 件の結合テストが通った"
