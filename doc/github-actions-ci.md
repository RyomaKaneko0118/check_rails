# GitHub Actions CI 解説

`.github/workflows/ci.yml` の解説。Rails 8.1 の `rails new` が生成する標準 CI をベースに、PostgreSQL 用の調整と RuboCop キャッシュを加えた構成になっている。

## 全体像

| ジョブ | 役割 | 主なコマンド |
| --- | --- | --- |
| `scan_ruby` | Rails アプリ本体とゲムの脆弱性検査 | `bin/brakeman` / `bin/bundler-audit` |
| `scan_js` | importmap 経由の JS 依存の脆弱性検査 | `bin/importmap audit` |
| `lint` | Ruby コードスタイル検査 | `bin/rubocop -f github` |
| `test` | 単体・結合テスト | `bin/rails db:test:prepare test` |
| `system-test` | ブラウザを使ったシステムテスト | `bin/rails db:test:prepare test:system` |

5 つのジョブは互いに `needs` で繋がっていないため**すべて並列に実行**される。どれか 1 つでも落ちればワークフロー全体が失敗する。

## 起動条件

```yaml
on:
  pull_request:
  push:
    branches: [ main ]
```

- `pull_request`: PR が作られたとき、および PR のブランチに push されたとき。ブランチの絞り込みがないので、どのブランチ向けの PR でも動く。
- `push` (`main` のみ): マージ後の `main` を検証する。トピックブランチへの push では走らないので、PR を出す前の細かい push で CI 時間を消費しない。

結果として「PR 中は PR イベントで 1 回」「マージ後に push イベントで 1 回」という回り方になる。

## 全ジョブ共通のステップ

```yaml
- uses: actions/checkout@v6
- uses: ruby/setup-ruby@v1
  with:
    bundler-cache: true
```

- `actions/checkout@v6` — リポジトリをランナー上に取得する。
- `ruby/setup-ruby@v1` — Ruby をインストールする。バージョンは明示されていないので `.ruby-version`（このリポジトリでは `ruby-4.0.7`）が読まれる。
- `bundler-cache: true` — `bundle install` の実行と、`Gemfile.lock` をキーにした vendor/bundle のキャッシュ保存・復元をまとめて行う。これがあるので各ジョブに `bundle install` ステップは要らない。

## scan_ruby — Rails 側のセキュリティ検査

```yaml
- run: bin/brakeman --no-pager
- run: bin/bundler-audit
```

- **Brakeman** は Rails 専用の静的解析ツール。SQL インジェクション、XSS、マスアサインメント、安全でないリダイレクトなどをソースコードから検出する。アプリを起動せずに解析するため高速。`--no-pager` は対話的なページャを無効化して CI ログにそのまま出力させるための指定。
- **bundler-audit** は `Gemfile.lock` を ruby-advisory-db（既知の脆弱性データベース）と突き合わせ、脆弱なバージョンのゲムが使われていないかを調べる。誤検知や対応保留の警告は `config/bundler-audit.yml` で無視できる。

どちらも `Gemfile` の `development, test` グループに入っており、`bin/` 配下の binstub 経由で呼ばれる。

## scan_js — JavaScript 依存の検査

```yaml
- run: bin/importmap audit
```

このアプリは importmap-rails を使っていて、npm / yarn ではなく `config/importmap.rb` で CDN 上の JS モジュールを直接指定する。`importmap audit` はそこにピン留めされたパッケージとバージョンを npm の脆弱性情報と照合する。Node.js のインストールが不要なのはこのため。

## lint — RuboCop とキャッシュ

```yaml
env:
  RUBOCOP_CACHE_ROOT: tmp/rubocop
```

RuboCop のキャッシュ出力先をリポジトリ内の `tmp/rubocop` に固定し、それを `actions/cache@v4` で永続化している。

```yaml
env:
  DEPENDENCIES_HASH: ${{ hashFiles('.ruby-version', '**/.rubocop.yml', '**/.rubocop_todo.yml', 'Gemfile.lock') }}
with:
  key: rubocop-${{ runner.os }}-${{ env.DEPENDENCIES_HASH }}-${{ github.ref_name == github.event.repository.default_branch && github.run_id || 'default' }}
  restore-keys: |
    rubocop-${{ runner.os }}-${{ env.DEPENDENCIES_HASH }}-
```

キャッシュキーの組み立て方がこのワークフローで一番込み入った部分なので、分解して見る。

1. `DEPENDENCIES_HASH` — Ruby のバージョン、RuboCop の設定ファイル群、`Gemfile.lock` の内容から算出したハッシュ。これらが変わると検査結果も変わりうるので、キャッシュを作り直す必要がある。
2. キー末尾の三項演算 — `github.ref_name` がデフォルトブランチ（`main`）と一致する場合だけ `github.run_id` を、そうでなければ文字列 `default` を使う。
   - `main` への push では実行ごとに一意なキーになり、**毎回新しいキャッシュが保存される**。
   - PR では全 PR が `...-default` という同じキーを共有する。
3. `restore-keys` — 完全一致するキーがなくても、`rubocop-<OS>-<ハッシュ>-` で始まる直近のキャッシュを前方一致で拾う。

GitHub Actions のキャッシュは「同じキーが既にあれば上書きしない」仕様なので、`main` 側で run_id を混ぜて毎回新しいキーを作り、PR 側は `restore-keys` でその最新版を読むだけ、という役割分担になる。これで PR のキャッシュが互いを汚さず、かつ `main` の最新状態を再利用できる。

> 補足: GitHub のキャッシュはブランチのスコープ制限があり、PR からはそのブランチと基底ブランチ（`main`）のキャッシュだけが見える。上の設計はこの制約と噛み合っている。

```yaml
- run: bin/rubocop -f github
```

`-f github` は GitHub Actions 用のフォーマッタ。違反をワークフローコマンド形式で出力するので、PR の該当行にアノテーションとして表示される。

スタイル規約は `.rubocop.yml` が `rubocop-rails-omakase` を継承しており、DHH 流の Rails 標準スタイルをそのまま採用している。

## test — 単体・結合テスト

```yaml
services:
  postgres:
    image: postgres
    env:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports:
      - 5432:5432
    options: --health-cmd="pg_isready" --health-interval=10s --health-timeout=5s --health-retries=3
```

`services` はジョブ実行中だけ立ち上がるサイドカーコンテナ。ここでは PostgreSQL をランナーの `localhost:5432` に公開している。`--health-cmd=pg_isready` により、GitHub Actions は DB が接続を受け付けられる状態になるまで待ってからステップを開始する（起動待ちの `sleep` を書かなくてよい）。

```yaml
- run: sudo apt-get update && sudo apt-get install --no-install-recommends -y libpq-dev libvips
```

- `libpq-dev` — `pg` ゲムのネイティブ拡張ビルドに必要。
- `libvips` — Active Storage の画像変換（`image_processing` ゲム）が使う画像処理ライブラリ。

```yaml
env:
  RAILS_ENV: test
  DATABASE_URL: postgres://postgres:postgres@localhost:5432
run: bin/rails db:test:prepare test
```

`DATABASE_URL` が `config/database.yml` の設定より優先されるため、開発環境（compose の `db` ホスト）とは別に CI 用の接続先を指定できる。`db:test:prepare` はテスト用 DB を作成しスキーマを流し込み、その後 `test` が Minitest を実行する。

`postgres` と並んで `redis` サービス（Valkey）も立ち上がる。

```yaml
  redis:
    image: valkey/valkey:9.1.2-trixie
    ports:
      - 6379:6379
    options: --health-cmd "valkey-cli ping" --health-interval 10s --health-timeout 5s --health-retries 5
```

ヘルスチェックが `redis-cli` ではなく `valkey-cli` なのは、Valkey イメージに `redis-cli` が入っていないため。アプリへは `REDIS_URL` ではなく `REDIS_HOST: localhost` だけを渡し、DB 番号は `config/redis.yml` が `RAILS_ENV` から決める（CI 用に URL を書き分ける必要がない）。詳細は [Redis (Valkey) 構成メモ](redis.md) を参照。

`RAILS_MASTER_KEY` はコメントアウトされたまま。暗号化された credentials をテストで読む必要が出たときに有効化する枠。

## system-test — ブラウザテスト

`test` ジョブとほぼ同じ構成で、実行コマンドが `bin/rails db:test:prepare test:system` になっている。Capybara + selenium-webdriver で実際の Chrome を動かし、画面操作レベルの検証を行う（ランナーには Chrome とドライバがプリインストールされている）。

```yaml
- name: Keep screenshots from failed system tests
  uses: actions/upload-artifact@v4
  if: failure()
  with:
    name: screenshots
    path: ${{ github.workspace }}/tmp/screenshots
    if-no-files-found: ignore
```

- `if: failure()` — 直前までのステップが失敗したときだけ実行される。Rails のシステムテストは失敗時に `tmp/screenshots` へ自動でスクリーンショットを保存するので、それを成果物としてアップロードしておけば、実行ログだけでは分からない画面の状態を後から確認できる。
- `if-no-files-found: ignore` — スクリーンショットが 1 枚もない場合でも警告やエラーにしない。

`test` を分けている理由はブラウザを起動するぶん実行時間が長く、並列に走らせたほうが全体のフィードバックが速くなるため。

## 関連: Dependabot

CI ではないが `.github/dependabot.yml` が対になっている。

```yaml
version: 2
updates:
- package-ecosystem: bundler
  directory: "/"
  schedule:
    interval: weekly
  open-pull-requests-limit: 10
- package-ecosystem: github-actions
  directory: "/"
  schedule:
    interval: weekly
  open-pull-requests-limit: 10
```

- `bundler` — `Gemfile.lock` のゲムを毎週チェックし、更新があれば PR を作る。
- `github-actions` — `ci.yml` で使っている `actions/checkout` や `ruby/setup-ruby` のバージョンを追従させる。
- 上げた PR には上記の CI がそのまま走るので、「更新 → 自動検証」が回る。

## ローカルでの再現

CI と同じ検査は手元でも実行できる。

```sh
docker compose run --rm web bin/brakeman --no-pager
docker compose run --rm web bin/bundler-audit
docker compose run --rm web bin/importmap audit
docker compose run --rm web bin/rubocop
docker compose run --rm web bin/rails db:test:prepare test
```

まとめて実行するなら Rails 8.1 の `bin/ci` が使える。

```sh
docker compose run --rm web bin/ci
```

実行内容は `config/ci.rb`（`ActiveSupport::ContinuousIntegration`）に定義されていて、GitHub Actions 側とは完全には一致しない点に注意。

- ワークフローにない: `bin/setup --skip-server`、`db:seed:replant` によるシード確認
- `config/ci.rb` 側で無効: システムテスト（コメントアウト）
- Brakeman のオプションが異なる（`--quiet --exit-on-warn --exit-on-error`）

どちらか一方を変えたときは、もう一方も揃えるか意図的にずらしているのかを確認しておくとよい。
