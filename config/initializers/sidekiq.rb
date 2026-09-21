# Sidekiq の接続先。REDIS_URL は使わない (env を暗黙に拾うと test が development の
# キューを読む) ため、config/redis.yml が環境ごとに決めた queue_url を明示する。
# 理由の詳細は doc/redis.md を参照。
redis_options = { url: Rails.application.config_for(:redis)[:queue_url] }

Sidekiq.configure_server do |config|
  config.redis = redis_options
end

Sidekiq.configure_client do |config|
  config.redis = redis_options
end
