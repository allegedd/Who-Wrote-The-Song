class SongsController < ApplicationController
  def index
    if params[:title].present?
      @songs = search_songs(params[:title], params[:artist])

      if @songs.size == 1
        redirect_to song_path(@songs.first.id)
      end
    else
      @songs = []
    end
  end

  def show
    @song = find_song_by_id(params[:id])

    if @song.nil?
      redirect_to root_path, alert: "楽曲が見つかりませんでした"
      return
    end

    # 作詞家・作曲家の他の作品を取得
    @composer_works = {}
    @lyricist_works = {}

    # 作曲家・作詞家のIDを収集
    composer_ids = @song.composers.select { |c| c.is_a?(Hash) && c[:mbid].present? }
    lyricist_ids = @song.lyricists.select { |l| l.is_a?(Hash) && l[:mbid].present? }

    # 並列処理でAPI呼び出しを高速化
    threads = []

    composer_ids.each do |composer|
      threads << Thread.new do
        # キャッシュを優先的にチェック
        cache_key = "artist_works:#{composer[:mbid]}"
        other_works = Rails.cache.read(cache_key)

        if other_works.nil?
          # キャッシュがない場合のみAPI呼び出し
          service = MusicBrainzService.new
          works = service.find_artist_works_fast(composer[:mbid], 20)
          other_works = works.reject { |work| work.id == @song.id }

          # 部分的なキャッシュを保存
          Rails.cache.write("#{cache_key}_partial", other_works, expires_in: 1.hour)
        end

        Thread.current[:result] = {
          type: :composer,
          name: composer[:name],
          data: {
            initial: other_works.take(10),
            has_more: other_works.size > 10,
            mbid: composer[:mbid]
          }
        }
      end
    end

    lyricist_ids.each do |lyricist|
      threads << Thread.new do
        # キャッシュを優先的にチェック
        cache_key = "artist_works:#{lyricist[:mbid]}"
        other_works = Rails.cache.read(cache_key)

        if other_works.nil?
          # キャッシュがない場合のみAPI呼び出し
          service = MusicBrainzService.new
          works = service.find_artist_works_fast(lyricist[:mbid], 20)
          other_works = works.reject { |work| work.id == @song.id }

          # 部分的なキャッシュを保存
          Rails.cache.write("#{cache_key}_partial", other_works, expires_in: 1.hour)
        end

        Thread.current[:result] = {
          type: :lyricist,
          name: lyricist[:name],
          data: {
            initial: other_works.take(10),
            has_more: other_works.size > 10,
            mbid: lyricist[:mbid]
          }
        }
      end
    end

    # 全スレッドの完了を待機
    threads.each do |thread|
      thread.join
      result = thread[:result]
      if result[:type] == :composer
        @composer_works[result[:name]] = result[:data]
      else
        @lyricist_works[result[:name]] = result[:data]
      end
    end
  end

  # 検索フォームからのリダイレクト
  def search
    redirect_to songs_path(title: params[:title], artist: params[:artist])
  end

  # アーティスト情報の非同期読み込み
  def load_artists
    song_ids = params[:song_ids]&.split(",") || []

    # まずキャッシュから取得を試行
    cached_results = []
    uncached_song_ids = []

    song_ids.each do |song_id|
      cached_artist = Rails.cache.read("song_artist:#{song_id}")
      if cached_artist
        cached_results << {
          id: song_id,
          artist: cached_artist
        }
      else
        uncached_song_ids << song_id
      end
    end

    api_results = []
    if uncached_song_ids.any?
      max_concurrent_threads = 5
      service = MusicBrainzService.new

      # より小さなバッチで処理
      uncached_song_ids.each_slice(max_concurrent_threads) do |batch|
        # 各バッチを並列処理
        threads = batch.map do |song_id|
          Thread.new do
            begin
              song = service.find_work_by_id(song_id)
              artist_name = song&.artist || "情報なし"

              # 取得結果をキャッシュ
              Rails.cache.write("song_artist:#{song_id}", artist_name, expires_in: 1.hour)

              Thread.current[:result] = {
                id: song_id,
                artist: artist_name
              }
            rescue => e
              Rails.logger.error "Error loading artist for #{song_id}: #{e.message}"
              Thread.current[:result] = {
                id: song_id,
                artist: "情報なし"
              }
            end
          end
        end

        # バッチの結果を収集
        batch_results = threads.map do |thread|
          # 最大5秒でタイムアウト
          if thread.join(5)
            thread[:result]
          else
            Rails.logger.warn "Thread timeout for artist loading"
            thread.kill
            nil
          end
        end.compact

        api_results.concat(batch_results)

        # バッチ間の待機
        sleep(0.1) if uncached_song_ids.size > max_concurrent_threads
      end
    end

    all_results = cached_results + api_results

    render json: { artists: all_results }
  end

  def artist_works
    artist_id = params[:artist_id]
    current_song_id = params[:current_song_id]
    offset = params[:offset]&.to_i || 10

    # キャッシュから作品を取得
    other_works = Rails.cache.read("artist_works:#{artist_id}")

    if other_works.nil?
      # キャッシュにない場合のみAPI呼び出し
      service = MusicBrainzService.new
      all_works = service.find_artist_works_fast(artist_id, 100)
      other_works = all_works.reject { |work| work.id == current_song_id }
      # 新しいキャッシュを保存
      Rails.cache.write("artist_works:#{artist_id}", other_works, expires_in: 1.hour)
    else
      # キャッシュされたデータから現在の楽曲を除外
      other_works = other_works.reject { |work| work.id == current_song_id }
    end

    # 10件ずつ表示
    limit = 10
    works_to_show = other_works[offset, limit] || []
    has_more = other_works.size > (offset + limit)

    render json: {
      works: works_to_show.map { |work| {
        id: work.id,
        title: work.title,
        artist: work.artist,
        creator_names: work.creator_names
      } },
      has_more: has_more
    }
  end

  # YouTube動画検索エンドポイント
  def youtube_search
    title = params[:title]
    artist = params[:artist]

    youtube_service = YoutubeService.new
    result = youtube_service.search_videos(title, artist)

    render json: result
  rescue => e
    Rails.logger.error "YouTube search controller error: #{e.message}"
    render json: { videos: [], error: e.message }, status: :ok
  end

  private

  def search_songs(title, artist = nil)
    MusicBrainzService.new.search_works(title, artist)
  end

  def find_song_by_id(id)
    service = MusicBrainzService.new
    # Work IDで検索、見つからなければRecording IDで検索
    service.find_work_by_id(id) || service.find_recording_by_id(id)
  end
end
