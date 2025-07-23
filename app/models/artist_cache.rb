class ArtistCache < ApplicationRecord
  validates :work_id, presence: true, uniqueness: true
  validates :cached_at, presence: true
  validates :access_count, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :popular, -> { order(access_count: :desc) }
  scope :recent, -> { order(last_accessed_at: :desc) }
  scope :oldest, -> { order(cached_at: :asc) }

  # キャッシュからアーティスト情報を取得し、アクセス統計を更新
  def self.get_artist_with_stats(work_id)
    cache = find_by(work_id: work_id)
    return nil unless cache

    cache.increment!(:access_count)
    cache.touch(:last_accessed_at)

    cache.artist_name
  end

  # アーティスト情報をキャッシュに保存
  def self.cache_artist(work_id, artist_name)
    find_or_create_by(work_id: work_id) do |cache|
      cache.artist_name = artist_name
      cache.cached_at = Time.current
      cache.access_count = 0
    end
  end

  # 複数のwork_idに対してバッチでキャッシュ取得
  def self.get_artists_batch(work_ids)
    where(work_id: work_ids).pluck(:work_id, :artist_name).to_h
  end

  # 統計情報取得
  def self.stats
    {
      total_cached: count,
      most_popular: popular.limit(10).pluck(:work_id, :artist_name, :access_count),
      recent_additions: recent.limit(10).pluck(:work_id, :artist_name, :cached_at),
      total_storage_mb: estimate_storage_size
    }
  end

  # 手動でキャッシュを更新（データ修正時用）
  def self.refresh_cache(work_id)
    cache = find_by(work_id: work_id)
    return nil unless cache

    # 既存キャッシュを削除して再取得を促す
    cache.destroy
    Rails.logger.info "Refreshed cache for work: #{work_id}"
  end

  private

  def self.estimate_storage_size
    # 概算：work_id(36) + artist_name(平均50) + その他(50) = 約136 bytes per record
    (count * 136.0 / 1024 / 1024).round(2)
  end
end
