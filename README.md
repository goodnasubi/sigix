# sigix

Sigil で書いた Web サーバ。段階 1（静的ファイル配信）と段階 2（リバースプロキシ・条件付き GET）を実装済み。
設計は sigil リポジトリの ADR 0056（`docs/decisions/0056-sigix-web-server.md`）。

## 使い方

```sh
sigil build main.sigil main -o sigix-server
./sigix-server '[--listen,127.0.0.1:8080,--root,/srv/www]'
```

Sigil にはまだ argv を直接受ける API が無いため、引数は 1 つの角括弧リスト（`List<String>`）として渡す。

| 設定 | 引数 | 環境変数 | 既定値 |
|---|---|---|---|
| 待受アドレス | `--listen ADDR:PORT`（IPv6 は `[::1]:8080`） | `SIGIX_LISTEN` | `127.0.0.1:8080` |
| 配信ルート | `--root DIR` | `SIGIX_ROOT` | なし（必須） |
| 応答本体の上限 | `--max-response-body=BYTES` | `SIGIX_MAX_RESPONSE_BODY` | 1 MiB（範囲 1〜64 MiB） |
| 設定ファイル（JSON） | `--config FILE` | `SIGIX_CONFIG` | なし（後述） |

- 優先順位は 引数 > 環境変数 > 設定ファイル > 既定値。`--config` を使うときは `--root` は不要（指定すると、設定ファイルに `/` の経路が無い場合だけ、その `/` を静的配信する経路として足す）。
- 数値は `--max-response-body=67108864` のように `=` で書く（リスト要素が数字だけになると Int と解釈されて拒否されるため）。
- 不正な値・範囲外の値・開けないルートは起動時に拒否する（fail-closed）。設定の再読込は再起動のみ。
- 設定エラー時もプロセスの終了コードは 0 で、戻り値（2 = 設定/ルート、3 = 待受失敗）が標準出力の最終行に出る（言語側に終了コード API が無いため）。

## 振る舞い

- GET / HEAD のみ。他のメソッドは 405（`Allow: GET, HEAD`）。
- 200: 本体、`Content-Type`（拡張子表。未知は `application/octet-stream`）、`Content-Length`。
- 存在しない経路は 404。ディレクトリは `index.html` があれば返し、無ければ 404（403 にしない）。autoindex なし。
- `/docs`（末尾 `/` なしのディレクトリ）は 301 `Location: /docs/`（クエリは落とす）。通常ファイルへの末尾 `/` は 404。
- 経路の正規化: `.`・`..`・バックスラッシュ・制御文字・エンコードされた区切り（`%2F`）・`//`・不正な UTF-8 は 400。
- ファイルは ADR 0049 の `Dir` 経由で `follow_symlinks(false)` で開く（シンボリックリンクは配信しない）。
- 上限を超えるファイルは全体を読まず、固定本体の 500 を返す。読み取りは 16 KiB 単位。
- ドットファイルは配信する（隠さない）。
- アクセスログ（標準出力）: `時刻(unix秒) メソッド 経路 HTTP/1.x 状態 バイト数`。応答の送信前に書く。HEAD は 0 バイト。

## 設定ファイルとリバースプロキシ（段階 2）

```sh
./sigix-server '[--config=/etc/sigix/config.json]'
```

```json
{
  "listen": "127.0.0.1:8080",
  "max_response_body": 1048576,
  "trusted_proxies": ["127.0.0.1", "::1", "10.0.0.0/8"],
  "connect_timeout_ms": 3000,
  "read_timeout_ms": 30000,
  "routes": [
    { "prefix": "/api/", "type": "proxy", "backends": ["127.0.0.1:9000", "127.0.0.1:9001"], "host": "preserve" },
    { "prefix": "/static/", "type": "static", "root": "/srv/static" },
    { "prefix": "/", "type": "static", "root": "/srv/www" }
  ]
}
```

- 経路（`routes`）は接頭辞で振り分け、**最長一致**。`prefix` は `/` で始まり `/` で終わる。静的配信の経路では接頭辞を除いた残りを `root` の中の経路にする（`/static/a.css` → `root/a.css`）。プロキシでは経路もクエリも**そのまま**（接頭辞を含めて）上流へ渡す。
- `backends` は **数値の IP:ポート**（`[::1]:9001` の形も可）。名前解決はしない（言語側の `net.connect` が数値アドレスのみのため）。経路ごとにラウンドロビン。重み付け・ヘルスチェック・フェイルオーバーはしない。
- `host`: `"preserve"`（既定。クライアントの Host を上流へ渡す）または `"backend"`（転送先の `IP:ポート` に書き換える）。
- `connect_timeout_ms`（既定 3000、1〜60000）・`read_timeout_ms`（既定 30000、1〜300000）。接続できない・時間切れ・応答が読めない・応答本文が `max_response_body` 超過のときは、固定本文 `Bad Gateway` の **502**。
- 不明なキー・型の違い・範囲外・不正なアドレス・重複した `prefix`・開けない `root`・読めない設定ファイルは**起動時に拒否**（fail-closed。終了コードの代わりに戻り値 2 が標準出力の最終行に出る）。再読込は再起動のみ。
- 要求・応答は解釈して組み直す（バイト列の素通しではない）。上流へは `Connection: close` の HTTP/1.1。ホップバイホップ（`Connection`・`Keep-Alive`・`Proxy-Authenticate`・`Proxy-Authorization`・`TE`・`Trailer`・`Transfer-Encoding`・`Upgrade`）と、`Connection` が名指しするヘッダは両方向で取り除く。
- `X-Forwarded-For` は、直接の接続元の IP を上流へ渡す（信頼する接続元には、届いた値の後ろに `, 接続元` と追記。信頼しない接続元の値は捨てて接続元の IP だけにする）。`Forwarded` / `X-Real-IP` は常に捨てる。`X-Forwarded-Proto` は信頼しない接続元には常に `http` で上書き（信頼する接続元は `https` のみ中継）。`trusted_proxies`（IPv4 / IPv4 CIDR / IPv6 単一アドレス。既定はループバック）は起動時に検査する。
- 応答は全体を読んでから返す（ストリーミングなし。上流の応答は `Content-Length`・チャンク・接続の切断のどれかで終わりを決める。`Content-Length` と `Transfer-Encoding` の併記、食い違う `Content-Length`、1xx、未対応の転送符号は 502）。応答の解釈は sigix の中の最小実装（`sigix/respparse.sigil`。言語側に `HttpResponseParser` が入ったら置き換える）。
- 条件付き GET: 静的ファイルに `ETag`（大きさと更新時刻から作る強い検証子）と `Last-Modified` を付け、`If-None-Match`（優先）・`If-Modified-Since`（IMF-fixdate のみ）が合えば本文を読まずに 304。`File.byte_len` / `File.mtime`（sigil ADR 0049 決定 8）を使う。
- アクセスログはプロキシの経路だけ末尾に `転送先 上流の状態` が付く: `1763784000 GET /api/v1/users HTTP/1.1 200 1024 127.0.0.1:9000 200`。502 のときの上流の状態は `-`。キャッシュヒット時は転送先が `cache` になる。

## 任意のキャッシュ連携（ADR 0059 段 4）

プロキシ経路ごとに `sigil-stash-kv` とのキャッシュ連携を任意で有効化できる。

```json
{
  "prefix": "/api/",
  "type": "proxy",
  "backends": ["127.0.0.1:9000"],
  "cache": {
    "backend": "127.0.0.1:6379",
    "ttl_sec": 60
  }
}
```

- `backend`: `sigil-stash-kv` の待受 `IP:ポート`（数値アドレスのみ）。
- `ttl_sec`: 応答の `Cache-Control` に明示的な `s-maxage` や `max-age` がなく `public` の場合に使う既定の TTL 秒数（1〜86400、既定値 60）。
- **キャッシュキー**: `prefix + ":" + host + ":" + path + ("?" + query)`（上限 512 バイト）。
- **キャッシュ可否の判定**:
  - 要求: `GET` のみ。`Authorization` または `Cookie` がある要求、`Cache-Control: no-store` / `no-cache`（引数指定付きを含む）を含む要求はキャッシュせず通過。`Cache-Control: max-age=0` は再検証不可のためキャッシュ取得を保守的に迂回。`max-age` / `min-fresh` 制約は現行 Age および残余鮮度と照合し未達時は通過。
  - 応答: 状態コード `200` のみ。`Set-Cookie` または `Vary` を含む応答、`Cache-Control: private` / `no-store` / `no-cache`（引数指定付きを含む）はキャッシュせず通過。
  - 有効期限: 応答の現行 `Age` を考慮し、残余鮮度（`s-maxage` > `max-age` > `ttl_sec` から `Age` を減算）を計算。残余鮮度が 0 以下の stale な応答はキャッシュせず通過。
  - 上限: 直列化後の応答サイズは 3072 バイト以下。超過時はキャッシュせず通過。
- **キャッシュヒット時の Age 更新**: 保存時の時刻および初期 Age メタデータを保持し、キャッシュヒット応答には経過時間を反映した現行の `Age` ヘッダを付与して返却。
- **変更成功後のキャッシュ無効化**: 変更メソッド（`POST` / `PUT` / `DELETE` / `PATCH` 等の非安全メソッド）で成功（状態コード 200〜399）した要求の通過後、対象 URI のキャッシュエントリを無効化（削除）。
- **フォールバック**: キャッシュミス、TTL 期限切れ、キー・値の上限超過、`sigil-stash-kv` の容量超過や接続・通信障害時は、安全にオリジンから取得してクライアントへ返す（クライアントへ 502 等のエラーを出さない）。
- 静的配信経路（`type: "static"`）への `cache` 指定は設定エラーとなる（fail-closed）。

## 既知の制約・範囲外

- TLS、HTTP/2、gzip、ストリーミング配信（プロキシも静的も全体を読んでから返す）、重み付け・ヘルスチェック・フェイルオーバー、設定の再読込（再起動のみ）。
- 接続元の IP は `TcpStream.peer_addr`（sigil #721）で取り、`trusted_proxies` と照合する（IPv4 は完全一致と CIDR、IPv6 は小文字にそろえた完全一致。IPv4 射影アドレス `::ffff:a.b.c.d` は IPv4 として扱う）。取れなかったときは不明（信頼しない）として、`X-Forwarded-For` を付けない。
- ETag は大きさと更新時刻（秒）から作る（ADR 0056 決定 5(c)）。同じ秒内に同じ長さで内容だけが変わった場合や、更新時刻を保つデプロイでは、古い検証子が一致して 304 になりうる（nginx / Apache の既定と同じ性質。内容ハッシュにすると 304 でも全体を読むことになるため採らない）。
- プロキシの読み取り上限は、チャンク形式の応答では枠のオーバーヘッド分（本文の 7 倍まで）広げる。復号後の本文は `max_response_body` で厳密に制限する。
- プロキシでの HEAD の応答は、上流の `Content-Length` を保てない（本文がないため 0 になる）。
- `File.read` が遅く（ネイティブで約 3.6 MB/s）、64 MiB のファイルは配信に約 18 秒かかる。
- 301 は、ディレクトリの存在を末尾 `/` なしの要求で観測できる（ADR 0056 決定 3 で許容）。

## テスト

```sh
SIGIL=/path/to/sigil ./test.sh
```

`sigil fmt --check`、`sigil check`、SIR 評価器での単体テスト、ネイティブ単体テスト、ネイティブバイナリへの curl 結合テスト（静的配信 `tests/e2e.sh` 55 件、プロキシ `tests/e2e_proxy.sh` 16 件、キャッシュ `tests/e2e_cache.sh` 23 件）を順に実行する。
CI は sigil の main コミットを固定してコンパイラをビルドし、同じ `test.sh` を実行する（`.github/workflows/ci.yml`）。
