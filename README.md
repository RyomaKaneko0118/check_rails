# check_rails

Ruby 4.0.7 / Node.js 26.9.0 / PostgreSQL 18.6 の Docker 開発環境。
Rails 8.1 (propshaft / importmap / solid_*) を PostgreSQL で動かす。

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
  max_connections: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
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

## Dockerfile の使い分け

| ファイル | 用途 |
| --- | --- |
| `Dockerfile` | 開発用。compose から使う。Node.js 同梱、root、`CMD ["bash"]` |
| `Dockerfile.production` | `rails new` が生成した本番用 (Kamal 向け)。compose からは使わない |

`rails new` は `Dockerfile` を本番用で上書きするので、再実行したら
同じように退避し直すこと。本番用は開発用と前提が違う:

- `WORKDIR /rails` (compose は `/app` にマウントする)
- `RAILS_ENV=production` / `BUNDLE_DEPLOYMENT=1` / `BUNDLE_WITHOUT=development`
- 最終段は非 root かつビルドツール無しなので、generator や `bundle install` は通らない
- `EXPOSE 80` + thruster 起動 (compose の `3000:3000` と噛み合わない)
- `COPY Gemfile Gemfile.lock` があるため、`bundle install` 前はビルドできない

## 設計メモ

- バージョンは秘密ではなくズレると困るので `compose.yaml` に直書きしてコミットする
- パスワードのみ `.env`（gitignore）に置き、`.env.example` は空欄の雛形
- `rails new` が置いた `.gitignore` の `/.env*` は `.env.example` も巻き込むので、
  `!/.env.example` で打ち消している
- healthcheck による起動待ちは入れていない。効くのは初回の一度だけで、
  失敗してもコマンドを叩き直せば済むため
- `DATABASE_URL` は使わない。Rails では全環境の設定を上書きするため、`RAILS_ENV=test`
  でのテスト実行が development の DB を破壊する。接続情報は部品で渡し、DB 名は
  `config/database.yml` が環境ごとに決める
- 同じ理由で `REDIS_URL` も使わない。`redis` ゲムが暗黙に拾うため、渡すのは
  `REDIS_HOST` だけにし、DB 番号は `config/redis.yml` が環境・用途ごとに決める
  → [doc/redis.md](doc/redis.md)
