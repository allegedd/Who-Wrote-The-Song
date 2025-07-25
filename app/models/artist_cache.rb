class ArtistCache < ApplicationRecord
  validates :work_id, presence: true, uniqueness: true
  validates :cached_at, presence: true
  validates :access_count, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :popular, -> { order(access_count: :desc) }
  scope :recent, -> { order(last_accessed_at: :desc) }
  scope :oldest, -> { order(cached_at: :asc) }

  # アーティスト情報を取得し、アクセス統計を更新
  def self.get_artist_with_stats(work_id)
    cache = find_by(work_id: work_id)
    return nil unless cache

    cache.increment!(:access_count)
    cache.touch(:last_accessed_at)

    cache.artist_name
  end

  # アーティスト情報を保存
  def self.cache_artist(work_id, artist_name)
    cache = find_or_initialize_by(work_id: work_id)
    cache.artist_name = artist_name
    cache.cached_at = Time.current if cache.new_record?
    cache.access_count ||= 0
    cache.save
  end

  # 複数のwork_idに対してバッチ取得
  def self.get_artists_batch(work_ids)
    where(work_id: work_ids).pluck(:work_id, :artist_name).to_h
  end

  # 統計更新なしで取得
  def self.get_artist_fast(work_id)
    find_by(work_id: work_id)&.artist_name
  end

  # キャッシュを手動更新
  def self.refresh_cache(work_id)
    cache = find_by(work_id: work_id)
    return nil unless cache

    cache.destroy
  end
end
