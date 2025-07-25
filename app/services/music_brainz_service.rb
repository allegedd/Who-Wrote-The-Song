# MusicBrainz APIとの通信を担当するサービスクラス
# 作品検索、アーティスト情報取得、キャッシュ管理など
class MusicBrainzService
  BASE_URL = ENV.fetch("MUSICBRAINZ_API_URL", "http://localhost:5000/ws/2")

  def initialize
    @client = HTTParty
  end

  # 作品検索のメインメソッド
  # タイトルとアーティストで検索し、Work検索とRecording検索を組み合わせて結果を返す
  def search_works(title, artist = nil)
    start_time = Time.current

    if title.present? && artist.present?
      work_results = search_works_only(title, artist)

      elapsed = (Time.current - start_time) * 1000
      if elapsed > 1500
        return work_results.take(10)
      end

      recording_results = search_recordings_for_works(title, artist)

      if recording_results.any?
        combined_results = (recording_results + work_results).uniq { |song| song.id }
        combined_results.take(10)
      else
        work_results.take(10)
      end
    else
      search_works_only(title, artist).take(10)
    end
  end

  # Work IDから詳細情報を取得
  # キャッシュを活用して高速化
  def find_work_by_id(mbid)
    cache_key = "work:#{mbid}"
    cached_work = Rails.cache.read(cache_key)
    return cached_work if cached_work

    url = "#{BASE_URL}/work/#{mbid}"

    response = @client.get(url, {
      query: {
        fmt: "json",
        inc: "artist-rels+recording-rels"
      },
      timeout: 2
    })

    if response.success?
      work = parse_work_detail(response.parsed_response)

      if work
        Rails.cache.write(cache_key, work, expires_in: 24.hours)
        Rails.cache.write("song_artist:#{mbid}", work.artist, expires_in: 1.hour)
      end

      work
    else
      Rails.logger.error "MusicBrainz API Error: #{response.code} - #{response.message}"
      nil
    end
  rescue StandardError => e
    Rails.logger.error "MusicBrainz Service Error: #{e.message}"
    nil
  end


  # アーティストIDから作品一覧を高速取得
  # 詳細情報の取得をスキップして高速化
  def find_artist_works_fast(artist_mbid, limit = 10)
    query = "arid:#{artist_mbid}"

    response = @client.get("#{BASE_URL}/work", {
      query: {
        query: query,
        fmt: "json",
        inc: "artist-rels",
        limit: limit
      },
      timeout: 25
    })

    if response.success?
      parse_works_response_fast(response.parsed_response)
    else
      Rails.logger.error "MusicBrainz API Error: #{response.code} - #{response.message}"
      []
    end
  rescue StandardError => e
    Rails.logger.error "MusicBrainz Service Error: #{e.message}"
    []
  end

  private # ===== プライベートメソッド =====

  # Work APIのみを使用した検索
  # タイトルとアーティストで作品を検索
  def search_works_only(title, artist = nil)
    query = build_work_query(title, artist)
    url = "#{BASE_URL}/work"


    params = {
      query: query,
      fmt: "json",
      inc: "artist-rels+recording-rels",
      limit: 10,
      sort: "score"
    }


    response = @client.get(url, {
      query: params,
      timeout: 2
    })


    if response.success?
      works = parse_works_response(response.parsed_response)

      if artist.present?
        filtered_works = filter_works_by_artist(works, artist)
        works = filtered_works
      end

      works.uniq { |song| song.id }
    else
      Rails.logger.error "Work API Error: #{response.code} - #{response.message}"
      []
    end
  rescue StandardError => e
    Rails.logger.error "Work Search Error: #{e.message}"
    []
  end

  # Recording APIを使用してWorkを検索
  # 特定のアーティストによる録音からWork情報を取得
  def search_recordings_for_works(title, artist)
    query = "recording:\"#{escape_query(title)}\" AND artist:\"#{escape_query(artist)}\""
    url = "#{BASE_URL}/recording"


    # Step 1: Search for recordings (without relations)
    params = {
      query: query,
      fmt: "json",
      inc: "artist-credits",
      limit: 5,
      sort: "score"
    }


    response = @client.get(url, {
      query: params,
      timeout: 2
    })

    if response.success?
      recordings = response.parsed_response.dig("recordings") || []

      works = []
      recordings.each do |recording|
        recording_id = recording["id"]
        next unless recording_id

        detail_response = @client.get("#{BASE_URL}/recording/#{recording_id}", {
          query: {
            fmt: "json",
            inc: "artist-credits+work-rels"
          },
          timeout: 2
        })

        if detail_response.success?
          detailed_recording = detail_response.parsed_response
          work_relations = (detailed_recording["relations"] || []).select { |r| r["type"] == "performance" && r["target-type"] == "work" }


          work_relations.each do |rel|
            work_data = rel["work"]
            next unless work_data

            artist_name = extract_artist_from_recording(detailed_recording)

            works << Song.new(
              id: work_data["id"],
              title: work_data["title"],
              artist: artist_name,
              type: work_data["type"] || "Song",
              composers: [],
              lyricists: []
            )
          end
        else
        end
      end

      works.uniq { |song| song.id }
    else
      []
    end
  rescue StandardError
    []
  end

  # Recordingデータからアーティスト名を抽出
  def extract_artist_from_recording(recording)
    artist_credits = recording["artist-credit"] || []
    return "" unless artist_credits.any?

    artist_credits.first["artist"]["name"] rescue ""
  end

  # 検索クエリを構築
  # タイトルがある場合はタイトル優先で検索
  def build_work_query(title, artist = nil)
    query = if title.present? && artist.present?
      title
    elsif title.present?
      title
    elsif artist.present?
      escaped_artist = escape_query(artist)
      "artist:\"#{escaped_artist}\""
    else
      "*:*"
    end

    query
  end

  def escape_query(text)
    text.gsub('"', '\"')
  end

  # アーティスト名でWorkをフィルタリング
  # 演奏者、作曲者、作詞者でマッチング
  def filter_works_by_artist(works, target_artist)
    works.select do |song|
      artist_match = song.artist&.include?(target_artist)
      composer_match = song.composers.any? { |c| c[:name]&.include?(target_artist) }
      lyricist_match = song.lyricists.any? { |l| l[:name]&.include?(target_artist) }

      artist_match || composer_match || lyricist_match
    end
  end

  def extract_artist_from_work_search(work)
    ""
  end

  # Work APIのレスポンスをパース
  # Songオブジェクトの配列を生成し、スコア順でソート
  def parse_works_response(response)
    works = response.dig("works") || []

    songs_with_metadata = works.map.with_index do |work, index|
      artist_name = extract_artist_from_work_search(work)

      song = Song.new(
        id: work["id"],
        title: work["title"],
        artist: artist_name,
        type: work["type"],
        composers: extract_composers(work),
        lyricists: extract_lyricists(work),
        loading_artist: true  # 常に読み込み中として表示
      )

      {
        song: song,
        score: work["score"] || 0,
        original_index: index
      }
    end.compact

    songs = sort_by_score_and_date(songs_with_metadata)

    # パフォーマンス最適化：初期表示ではアーティスト情報の取得をスキップ
    # populate_artists_from_cache(songs) をコメントアウト
    # アーティスト情報はフロントエンドから非同期で取得

    songs
  end

  def sort_by_score_and_date(songs_with_metadata)
    songs_with_metadata
      .sort_by { |item| [ -item[:score], item[:original_index] ] }
      .map { |item| item[:song] }
  end

  # DBキャッシュからアーティスト情報を一括取得
  # 未キャッシュ分は並列処理で取得
  def populate_artists_from_cache(songs)
    work_ids = songs.map(&:id)

    cached_artists = ArtistCache.get_artists_batch(work_ids)
    uncached_work_ids = work_ids - cached_artists.keys

    songs.each do |song|
      if cached_artist = cached_artists[song.id]
        song.artist = cached_artist
        song.loading_artist = false
      end
    end

    if uncached_work_ids.any?
      uncached_songs = songs.select { |song| uncached_work_ids.include?(song.id) }
      fetch_artists_in_parallel(uncached_songs)
    end

    songs
  end

  # 複数のアーティスト情報を並列取得
  # スレッドを使用して高速化
  def fetch_artists_in_parallel(songs)
    max_threads = [ songs.size, 3 ].min
    batch_size = [ songs.size / max_threads, 2 ].max
    songs.each_slice(batch_size).map do |song_batch|
      Thread.new do
        song_batch.each_with_index do |song, index|
          sleep(0.1) if index > 0
          fetch_and_cache_artist(song)
        end
      end
    end.each(&:join)
  end

  # 単一の曲のアーティスト情報を取得してキャッシュ
  # タイムアウト時はリトライ処理
  def fetch_and_cache_artist(song)
    retries = 0
    begin
      work_detail = find_work_by_id(song.id)
      artist_name = work_detail&.artist || "情報なし"

      cache_artist_safely(song.id, artist_name)
      song.artist = artist_name
      song.loading_artist = false

    rescue Net::TimeoutError, Net::OpenTimeout, Errno::ETIMEDOUT
      retries += 1
      if retries <= 1
        sleep(0.5)
        retry
      else
        cache_artist_safely(song.id, "タイムアウト")
        song.artist = "タイムアウト"
        song.loading_artist = false
      end
    rescue StandardError
      cache_artist_safely(song.id, "情報取得エラー")
      song.artist = "情報取得エラー"
      song.loading_artist = false
    end
  end

  # スレッドセーフなキャッシュ保存
  # 競合状態を考慮してリトライ処理
  def cache_artist_safely(work_id, artist_name)
    retries = 0
    begin
      ArtistCache.cache_artist(work_id, artist_name)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      retries += 1
      retry if retries < 2
    end
  end


  # Work情報のみを使用した高速パース
  # アーティスト情報の取得をスキップ
  def parse_works_response_fast(response)
    works = response.dig("works") || []

    works.map do |work|
      Song.new(
        id: work["id"],
        title: work["title"],
        artist: "",
        type: work["type"],
        composers: extract_composers(work),
        lyricists: extract_lyricists(work),
        loading_artist: true
      )
    end.compact
  end

  # Work詳細データをSongオブジェクトに変換
  def parse_work_detail(work_data)
    Song.new(
      id: work_data["id"],
      title: work_data["title"],
      artist: extract_artist_from_work(work_data),
      type: work_data["type"],
      composers: extract_composers(work_data),
      lyricists: extract_lyricists(work_data)
    )
  end

  # Workデータからアーティスト情報を抽出
  # Recordingの演奏者情報を取得して使用
  def extract_artist_from_work(work)
    relations = work.dig("relations") || []
    work_title = work["title"]


    performances = relations.select { |rel| rel["type"] == "performance" }

    original_performances = performances.select { |perf|
      attributes = perf["attributes"] || []
      attributes.empty?
    }
    target_performances = original_performances.any? ? original_performances : performances

    best_recording = target_performances.min_by do |perf|
      recording_title = perf.dig("recording", "title") || ""

      normalized_work_title = work_title.tr("！", "!").tr("　", " ").downcase
      normalized_rec_title = recording_title.tr("！", "!").tr("　", " ").downcase

      if normalized_work_title == normalized_rec_title
        0
      elsif normalized_rec_title.include?(normalized_work_title)
        1
      else
        2
      end
    end

    recording_id = best_recording&.dig("recording", "id")


    if recording_id
      fetch_artist_from_recording(recording_id)
    else
      ""
    end
  end

  # Recording IDからアーティスト情報を取得
  # キャッシュを活用してAPIリクエストを削減
  def fetch_artist_from_recording(recording_id)
    cache_key = "artist:recording:#{recording_id}"
    cached_artist = Rails.cache.read(cache_key)
    return cached_artist if cached_artist

    url = "#{BASE_URL}/recording/#{recording_id}"

    response = @client.get(url, {
      query: {
        fmt: "json",
        inc: "artist-credits"
      },
      timeout: 2
    })


    if response.success?
      artist_credits = response.parsed_response["artist-credit"] || []

      artist_name = artist_credits.map.with_index do |credit, index|
        name = credit.dig("artist", "name") || credit["name"] || ""
        joinphrase = credit["joinphrase"] || ""
        "#{name}#{joinphrase}"
      end.join


      Rails.cache.write(cache_key, artist_name, expires_in: 24.hours)

      artist_name
    else
      ""
    end
  rescue StandardError
    ""
  end


  def extract_composers(work)
    extract_artists_by_type(work, "composer")
  end

  def extract_lyricists(work)
    extract_artists_by_type(work, "lyricist")
  end

  # 指定タイプのアーティスト情報を抽出
  # composerまたはlyricistの関係情報を取得
  def extract_artists_by_type(work, type)
    relations = work.dig("relations") || []

    relations
      .select { |rel| rel["type"] == type }
      .map { |rel|
        {
          name: rel.dig("artist", "name"),
          mbid: rel.dig("artist", "id")
        }
      }
      .compact
  end
end
