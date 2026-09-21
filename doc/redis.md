# Redis (Valkey) 構成メモ

キャッシュ・Action Cable・ジョブのバックエンドとして Redis を使うための土台の解説。
**現時点では接続の土台だけが入っており、`Rails.cache` などの切り替えはまだ行っていない**（[未実装](#未実装-次のステップ)を参照）。

## 全体像

| ファイル | 役割 |
| --- | --- |
| `compose.yaml` | `redis` サービス（Valkey）の定義と、`web` への `REDIS_HOST` 受け渡し |
| `config/redis.yml` | 環境・用途ごとの接続先（DB 番号）の決定 |
| `Gemfile` | `redis` ゲム（`Rails.cache` と Action Cable の redis アダプタが要求する） |
| `.github/workflows/ci.yml` | `test` / `system-test` ジョブの `redis` サービス |

## `REDIS_URL` を使わない

`config/database.yml` で `DATABASE_URL` を避けたのと同じ判断を Redis にも適用している。compose から渡すのは `REDIS_HOST` だけで、URL は組み立てない。

理由は 2 つある。

1. **環境をまたいだ破壊。** `redis` ゲムは `Redis.new` 時に `ENV["REDIS_URL"]` を暗黙で拾う。全環境共通の 1 本を渡すと、`RAILS_ENV=test` での実行が development のキャッシュを読み書きしてしまう。`DATABASE_URL` を避けた理由と同じ構造。
2. **用途の混在。** Redis は 1 インスタンスに複数の論理 DB を持つ。キャッシュとジョブキューを同じ DB に同居させると、`Rails.cache.clear` や Sidekiq の `FLUSHDB` が互いを巻き込む。

そのため DB 番号は `config/redis.yml` が環境ごと・用途ごとに決める。

| | development | test | production |
| --- | --- | --- | --- |
| cache | 0 | 10 | 0 |
| cable | 1 | 11 | 1 |
| queue | 2 | 12 | 2 |

test を 10 番台に離してあるので、テスト実行が開発中のデータを壊さない。

## `config/redis.yml`

```yaml
<%
  host = ENV.fetch("REDIS_HOST", "redis")
  port = ENV.fetch("REDIS_PORT", "6379")
%>
default: &default
  host: <%= host %>
  port: <%= port %>

development:
  <<: *default
  cache_url: redis://<%= host %>:<%= port %>/0
  cable_url: redis://<%= host %>:<%= port %>/1
  queue_url: redis://<%= host %>:<%= port %>/2
```

読み出しは `Rails.application.config_for(:redis)`。

```ruby
config = Rails.application.config_for(:redis)
# => #<ActiveSupport::OrderedOptions {host: "redis", port: 6379,
#      cache_url: "redis://redis:6379/0", cable_url: ".../1", queue_url: ".../2"}>
```

- `config_for` は `Rails.env` のセクションを自動で選び、シンボルキーの `OrderedOptions` を返す。
- **initializer ではなく設定ファイルにしている理由**は評価順。`config.cache_store` は `config/environments/*.rb` で決まり、これは initializer より前に走る。`config_for` はこの時点で使えるので、environment ファイルから直接参照できる。
- URL を丸ごと持たせているのは、`cache_store` や `cable.yml` が URL 文字列を受け取る形だから。ホストとポートと DB 番号に分解して各所で組み立て直すより短い。

## compose の `redis` サービス

```yaml
  redis:
    image: valkey/valkey:9.1.2-trixie
    command: ["valkey-server", "--appendonly", "yes"]
    volumes:
      - redisdata:/data
```

- **Valkey を選んだ理由。** Redis 本家は 7.4 でライセンスを変更しており、Valkey は分岐時点の BSD ライセンスを維持している。プロトコル互換なので `redis` ゲムからは区別なく使える。実際 `INFO server` は互換用に `redis_version:7.2.4` と、実体の `valkey_version:9.1.2` の両方を返す。
- **`--appendonly yes`。** キャッシュ用途だけなら永続化は不要だが、将来ジョブキューを載せた場合にプロセス再起動でジョブが消えるのは致命的なので、最初から有効にしてある。
- バージョンは他サービス（`postgres:18.6-trixie`）と同様にパッチ版まで固定する。

`web` 側は接続先ホストだけを受け取る。

```yaml
    environment:
      REDIS_HOST: redis
```

`REDIS_HOST` は秘密でもホスト依存でもないので `.env` には置かず、`compose.yaml` に直書きしてコミットする（バージョン番号と同じ扱い）。

## CI

`test` / `system-test` ジョブに compose と同じイメージのサービスを置いている。

```yaml
      redis:
        image: valkey/valkey:9.1.2-trixie
        ports:
          - 6379:6379
        options: --health-cmd "valkey-cli ping" --health-interval 10s --health-timeout 5s --health-retries 5
```

```yaml
        env:
          REDIS_HOST: localhost
```

- ヘルスチェックは `redis-cli` ではなく **`valkey-cli`**。Valkey イメージに `redis-cli` は入っていない。
- 渡すのは `REDIS_HOST` のみ。`RAILS_ENV=test` なので `config/redis.yml` が自動的に 10 番台の DB を選ぶ。CI 用に URL を書き分ける必要がない。
- PostgreSQL 側が `DATABASE_URL` を使っているのと非対称だが、これは `rails new` 生成時のままの記述で、Redis 側だけ方針を揃えている。

## 疎通確認

```sh
docker compose exec web bin/rails console
```

```ruby
config = Rails.application.config_for(:redis)
redis  = Redis.new(url: config[:cache_url])

redis.ping                             # => "PONG"
redis.set("probe", "hello")
redis.get("probe")                     # => "hello"
redis.del("probe")

redis.connection                       # => {host: "redis", port: 6379, db: 0, ...}
```

`ping` が通るだけでなく **`connection[:db]` が想定どおりか**まで見る。意図しない DB に繋いでいても `ping` は成功するため。

環境分離の確認は、環境を変えて同じキーが見えないことで行う。

```sh
docker compose exec -e RAILS_ENV=test web bin/rails console
```

```ruby
redis = Redis.new(url: Rails.application.config_for(:redis)[:cache_url])
[Rails.env, redis.connection[:db], redis.get("probe")]
# => ["test", 10, nil]   ← development (db 0) の値が見えない
```

`valkey-cli` を直接叩く場合は web ではなく redis コンテナ側。

```sh
docker compose exec redis valkey-cli -n 0 keys '*'
```

### `Redis.new` を引数なしで呼ばない

```ruby
Redis.new        # => Redis::CannotConnectError: Connection refused - 127.0.0.1:6379
```

`REDIS_URL` を渡していないため、引数なしの `Redis.new` は既定値の `localhost:6379` に繋ぎに行って失敗する。ネット上の例が `Redis.new` だけで動いているのは `REDIS_URL` を設定しているからで、この構成では接続先の明示が必要になる。これは「環境ごとに DB を分ける」ことの対価。

なお、アプリコードから直接 `Redis.new` を呼ぶ機会は実際にはほとんどない（`Rails.cache` と Action Cable は設定側で URL を受け取るため）。ヘルパを用意するかどうかは、直接叩く用途が出てきてから判断する。

## 未実装 / 次のステップ

現状は接続の土台のみで、アプリの挙動は Redis 導入前と変わらない。

| | 現状 |
| --- | --- |
| `Rails.cache` | development: `:memory_store` / test: `:null_store` / production: 未設定 |
| Action Cable | development: `async` / production: `cable.yml` は `ENV["REDIS_URL"]` 参照のまま |
| ジョブ | Active Job のアダプタ未設定。`solid_queue` は Gemfile にあるが未インストール |

切り替える場合の要点。

1. **`Rails.cache`** — `config.cache_store = :redis_cache_store, { url: Rails.application.config_for(:redis)[:cache_url], error_handler: ... }`。`RedisCacheStore` は既定のエラーハンドラが接続例外を握ってログに落とすため、Redis が落ちてもアプリは止まらない（`read` は `nil`、`fetch` はブロックにフォールバック）。`error_handler` を明示するのは、その障害をログに埋もれさせずエラートラッカーへ送るため。test は `:null_store` のままにしてテスト間の汚染を避ける。
2. **Action Cable** — `cable.yml` の production の `ENV.fetch("REDIS_URL")` を `cable_url` 参照に直す。ただし複数プロセスで配信する必要が出るまで development は `async` で十分。
3. **ジョブ** — Redis に載せるなら Sidekiq、DB に載せるなら Solid Queue。ジョブは消失が致命的な一方 Redis の永続化運用は DB より手間がかかるので、秒間数百ジョブ級が見えるまでは Solid Queue が無難。

`solid_cache` / `solid_cable` / `solid_queue` は Gemfile に残っているが未インストール（`config/cache.yml` などが無く、マイグレーションも無い）。Redis に寄せる範囲が決まったら、使わないものは Gemfile と `config/database.yml` の production ブロック（`cache:` / `queue:` / `cable:`）から外す。
