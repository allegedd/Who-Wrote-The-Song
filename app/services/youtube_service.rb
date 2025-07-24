# YouTube Data API v3を使用した動画検索サービス
# 楽曲のプレビュー用にYouTube動画を検索
class YoutubeService
  BASE_URL = "https://www.googleapis.com/youtube/v3"

  def initialize
    @api_key = ENV["YOUTUBE_API_KEY"]
    @client = HTTParty
  end

  # APIリクエスト回数制限チェック（1日100回まで）
  def can_make_request?
    today = Date.current.to_s
    request_count_key = "youtube_requests:#{today}"
    current_count = Rails.cache.read(request_count_key) || 0
    
    if current_count >= 100  # 1日100回制限
      Rails.logger.warn "YouTube API daily limit reached: #{current_count}"
      return false
    end
    
    true
  end

  # APIリクエスト回数をカウント
  def increment_request_count
    today = Date.current.to_s
    request_count_key = "youtube_requests:#{today}"
    current_count = Rails.cache.read(request_count_key) || 0
    Rails.cache.write(request_count_key, current_count + 1, expires_in: 25.hours)
    Rails.logger.info "YouTube API requests today: #{current_count + 1}/100"
  end

  # 楽曲タイトルとアーティスト名で動画を検索
  # 複数のクエリパターンでフォールバック検索を実施
  def search_videos(title, artist = nil)
    return { videos: [], error: "APIキーが設定されていません" } unless @api_key.present?

    # キャッシュキーを生成（APIコスト削減のため）
    cache_key = "youtube_search:#{Digest::MD5.hexdigest("#{artist}:#{title}")}"
    
    # キャッシュから検索結果を取得（24時間保持）
    cached_result = Rails.cache.read(cache_key)
    if cached_result
      Rails.logger.info "YouTube search cache hit for: #{title} #{artist}"
      return cached_result
    end

    # APIリクエスト制限チェック
    unless can_make_request?
      return { videos: [], error: "1日のYouTube API制限に達しました。明日再度お試しください。" }
    end

    # 複数のクエリパターンを試行
    queries = build_search_queries(title, artist)
    last_error = nil
    
    queries.each_with_index do |query, index|
      # APIリクエスト回数をカウント
      increment_request_count
      
      params = {
        part: "snippet",
        q: query,
        type: "video",
        maxResults: 3,  # APIコスト節約のため3件に削減
        order: "relevance",
        key: @api_key
      }

      response = @client.get("#{BASE_URL}/search", {
        query: params,
        timeout: 5
      })

      if response.success?
        result = parse_search_response(response.parsed_response)
        
        # 結果が見つかったら即座に返す
        if result.any?
          Rails.logger.info "YouTube search successful with query: #{query}"
          success_result = { videos: result }
          # 成功した結果をキャッシュに保存（24時間）
          Rails.cache.write(cache_key, success_result, expires_in: 24.hours)
          return success_result
        end
      else
        error_details = response.parsed_response&.dig("error")
        error_message = error_details&.dig("message") || response.message
        error_reason = error_details&.dig("errors", 0, "reason")
        
        Rails.logger.warn "YouTube API error (#{response.code}): #{error_message}"
        Rails.logger.warn "Error reason: #{error_reason}" if error_reason
        Rails.logger.debug "Full error response: #{response.parsed_response.inspect}"
        
        # クォータエラーの場合は即座に返す
        if error_reason == "quotaExceeded"
          return { videos: [], error: "YouTube APIの利用制限に達しました" }
        end
        
        last_error = error_message
      end
    end
    
    Rails.logger.warn "No YouTube results found for: #{title} #{artist}"
    error_result = { videos: [], error: last_error }
    # エラー結果も短時間キャッシュ（1時間、無駄なリクエストを防ぐため）
    Rails.cache.write(cache_key, error_result, expires_in: 1.hour)
    error_result
  rescue StandardError => e
    Rails.logger.error "YouTube Service Error: #{e.message}"
    { videos: [], error: e.message }
  end

  private

  # 複数の検索クエリパターンを生成
  # より高い検索精度を実現するためのフォールバック戦略
  def build_search_queries(title, artist)
    queries = []
    
    if artist.present? && title.present?
      # パターン3: シンプルな組み合わせ
      queries << "#{artist} #{title}"
    elsif title.present?
      # タイトルのみの場合
      queries << title
    end
    
    # 空のクエリを除外
    queries.reject(&:blank?)
  end


  # YouTube検索レスポンスをパース
  # 動画ID、タイトル、チャンネル名、サムネイルを抽出
  def parse_search_response(response)
    items = response.dig("items") || []
    
    items.map do |item|
      {
        video_id: item.dig("id", "videoId"),
        title: item.dig("snippet", "title"),
        channel_title: item.dig("snippet", "channelTitle"),
        thumbnail_url: item.dig("snippet", "thumbnails", "medium", "url"),
        published_at: item.dig("snippet", "publishedAt")
      }
    end.compact.select { |video| video[:video_id].present? }
  end
end