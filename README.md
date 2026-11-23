# sigix

Sigil で書いた Web サーバ。段階 1（静的ファイル配信）を実装済み。段階 2（リバースプロキシ）は未着手。
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

- 優先順位は 引数 > 環境変数 > 既定値。
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

## 既知の制約・範囲外

- TLS、gzip、条件付き GET、ストリーミング配信、段階 2（リバースプロキシ）。
- `File.read` が遅く（ネイティブで約 3.6 MB/s）、64 MiB のファイルは配信に約 18 秒かかる。
- 301 は、ディレクトリの存在を末尾 `/` なしの要求で観測できる（ADR 0056 決定 3 で許容）。

## テスト

```sh
SIGIL=/path/to/sigil ./test.sh
```

`sigil fmt --check`、`sigil check`、SIR 評価器での単体テスト、ネイティブ単体テスト、ネイティブバイナリへの curl 結合テスト（`tests/e2e.sh`、55 件）を順に実行する。
CI は sigil の main コミットを固定してコンパイラをビルドし、同じ `test.sh` を実行する（`.github/workflows/ci.yml`）。
