# check_rails

Ruby 4.0.7 / Node.js 26.9.0 / PostgreSQL 18.6 の Docker 開発環境。

## セットアップ

```sh
cp .env.example .env
# .env の POSTGRES_PASSWORD を埋める (例: openssl rand -hex 16)

docker compose build
docker compose run --rm web rails new . --database=postgresql --force --skip-bundle
docker compose run --rm web bundle install
```

`rails new` の後、`config/database.yml` を以下に差し替える。

```yaml
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  host: <%= ENV.fetch("POSTGRES_HOST", "db") %>
  username: <%= ENV["POSTGRES_USER"] %>
  password: <%= ENV["POSTGRES_PASSWORD"] %>

development:
  <<: *default
  database: check_rails_development

test:
  <<: *default
  database: check_rails_test
```

```sh
docker compose run --rm web rails db:create
docker compose up
```

初回のみ postgres の初期化 (`initdb`) が間に合わず `rails db:create` が
`could not connect to server` で落ちることがある。数秒待って叩き直せばよい。

http://localhost:3000

## 設計メモ

- バージョンは秘密ではなくズレると困るので `compose.yaml` に直書きしてコミットする
- パスワードのみ `.env`（gitignore）に置き、`.env.example` は空欄の雛形
- healthcheck による起動待ちは入れていない。効くのは初回の一度だけで、
  失敗してもコマンドを叩き直せば済むため
- `DATABASE_URL` は使わない。Rails では全環境の設定を上書きするため、`RAILS_ENV=test`
  でのテスト実行が development の DB を破壊する。接続情報は部品で渡し、DB 名は
  `config/database.yml` が環境ごとに決める
