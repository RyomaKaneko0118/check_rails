# ジョブ (Sidekiq) 構成メモ

Active Job のバックエンドに Sidekiq を使う。キューは Redis の **db 2**（`config/redis.yml` の `queue_url`）。

## 構成

| ファイル | 役割 |
| --- | --- |
| `config/initializers/sidekiq.rb` | server / client の接続先 |
| `config/environments/development.rb` `production.rb` | `queue_adapter = :sidekiq` |
| `compose.yaml` の `worker` | `bundle exec sidekiq` を常駐させるコンテナ |
| `config/routes.rb` | 管理 UI (`/sidekiq`) のマウント |

環境ごとのアダプタ。

| | アダプタ | キューの置き場所 |
| --- | --- | --- |
| development | `:sidekiq` | Redis db 2 |
| test | `:test`（Rails 既定） | メモリ上。`ActiveJob::TestHelper` で検証する |
| production | `:sidekiq` | Redis db 2 |

test だけ Sidekiq にしていないのは、テストのたびに worker を動かす必要が生じるのと、ジョブの実行タイミングをテスト側で制御できなくなるため。

## 接続先

```ruby
# config/initializers/sidekiq.rb
redis_options = { url: Rails.application.config_for(:redis)[:queue_url] }

Sidekiq.configure_server { |config| config.redis = redis_options }
Sidekiq.configure_client { |config| config.redis = redis_options }
```

- **server と client の両方に設定する。** client（Rails 側、ジョブを積む）と server（worker、ジョブを取り出す）は別々に接続を持つ。片方だけ設定すると、もう片方が既定の `localhost:6379/0` を見に行って噛み合わない。
- `REDIS_URL` を使わない理由は [doc/redis.md](redis.md) と同じ。キャッシュ（db 0）と同居させると `Rails.cache.clear` や Sidekiq の管理操作が互いを巻き込む。
- 接続先はログで確認できる。

```
Sidekiq 8.1.7 connecting to Redis with options {size: 10, pool_name: "internal", url: "redis://redis:6379/2"}
```

## worker コンテナ

`compose.yaml` では web と worker が同じイメージ・同じ環境変数で動き、起動コマンドだけが違う。重複を避けるため共通部分を `x-app` アンカーに切り出した。

```yaml
x-app: &app
  build: ...
  volumes: ...
  environment: ...
  depends_on: [db, redis]

services:
  web:
    <<: *app
    ports: ["3000:3000"]

  worker:
    <<: *app
    command: ["bundle", "exec", "sidekiq"]
```

**worker は Sidekiq でも必要。** ジョブを取り出して実行する常駐プロセスが要る点はキューの置き場所とは関係がない。

```sh
docker compose up -d worker        # 常駐させる
docker compose logs -f worker      # 処理状況を見る
docker compose exec web bundle exec sidekiq   # 一時的に手元で動かす
```

## 永続化

ジョブは Redis 上にあるので、Redis のデータが飛べば積まれたジョブも失われる。`compose.yaml` の redis サービスには `--appendonly yes` を入れてあり、プロセス再起動では失われない。ただし DB のバックアップとは別系統になるので、**本番では Redis の永続化とバックアップを DB とは別に用意する必要がある**点に注意（ここが Solid Queue のような DB バックエンドとの運用上の最大の違い）。

`db 2` は Sidekiq 専用にしてあるので、キューを空にしたいときは他の用途を巻き込まずに落とせる。

```sh
docker compose exec redis valkey-cli -n 2 flushdb
```

## 動作確認

```ruby
# bin/rails runner
require "sidekiq/api"
SomeJob.perform_later("arg")
Sidekiq::Queue.new("default").size   # => 1 (未処理)
Sidekiq::Stats.new.processed         # => 処理済みの件数
Sidekiq::Stats.new.failed            # => 失敗件数
```

worker を動かすとキューが減り `processed` が増える。実際にこの流れで、エンキュー → worker が処理 → `queue 0 / processed 1 / failed 0`、までを確認してある。

## 管理 UI

`/sidekiq` にマウントしてある。**認証は掛けていない**（閲覧を許可する方針）。

```ruby
# config/routes.rb
require "sidekiq/web"

Rails.application.routes.draw do
  mount Sidekiq::Web => "/sidekiq"
end
```

Dashboard / Busy / Queues / Retries / Scheduled / Dead / Metrics の各タブが使える。表示されるのは `config/initializers/sidekiq.rb` で設定した接続先（db 2）の内容で、アプリが積んだジョブと同じキューを見ている。

**Sidekiq 8 に read-only モードは無い。** `Sidekiq::Web::Config` に該当する設定は存在せず、UI から実行できる操作（リトライ、削除、キューの破棄、worker の quiet/stop）も認証なしで誰でも叩ける。閲覧のみに制限したい場合は、参照系だけ通すミドルウェアを挟む形になる。

```ruby
# 例: GET 以外を弾いて閲覧専用にする場合
mount Rack::Builder.new {
  use(Class.new {
    def initialize(app) = @app = app
    def call(env) = env["REQUEST_METHOD"] == "GET" ? @app.call(env) : [ 405, {}, [ "read only" ] ]
  })
  run Sidekiq::Web
} => "/sidekiq"
```

公開ネットワークに出す場合は、前段（リバースプロキシや IP 制限）で絞ることを前提にする。

## solid_queue を使わない理由

Rails 8 の既定は DB バックエンドの Solid Queue で、`rails new` の Gemfile にも入っていたが外してある。キャッシュ・Action Cable と同じ Redis にジョブも寄せ、バックエンドを一本化する判断。

代わりに運用面では、上記のとおり Redis の永続化とバックアップを自前で用意する必要がある。
