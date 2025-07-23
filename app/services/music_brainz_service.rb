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
      timeout: 1
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

  def find_recording_by_id(mbid)
    url = "#{BASE_URL}/recording/#{mbid}"
    Rails.logger.info "Finding recording by ID: #{url}"
    
    response = @client.get(url, {
      query: {
        fmt: "json",
        inc: "work-rels+artist-credits"
      },
      timeout: 30
    })

    Rails.logger.info "Recording detail API Response: #{response.code}"

    if response.success?
      recording_data = response.parsed_response
      
      # Recording から Work への関連があるかチェック
      relations = recording_data["relations"] || []
      work_relation = relations.find { |rel| rel["type"] == "performance" }
      
      if work_relation && work_relation["work"]
        # Work情報がある場合は、Work詳細を取得
        work_id = work_relation["work"]["id"]
        Rails.logger.info "Found work relation, fetching work: #{work_id}"
        find_work_by_id(work_id)
      else
        # Work情報がない場合は、Recording情報から Song を作成
        Rails.logger.info "No work relation found, creating song from recording"
        create_song_from_recording(recording_data)
      end
    else
      Rails.logger.error "Recording API Error: #{response.code} - #{response.message}"
      nil
    end
  rescue StandardError => e
    Rails.logger.error "Recording Service Error: #{e.message}"
    nil
  end

  def find_artist_works(artist_mbid, limit = 10)
    query = "arid:#{artist_mbid}"
    
    response = @client.get("#{BASE_URL}/work", {
      query: {
        query: query,
        fmt: "json",
        limit: limit
      },
      timeout: 30
    })

    if response.success?
      parse_works_response(response.parsed_response)
    else
      Rails.logger.error "MusicBrainz API Error: #{response.code} - #{response.message}"
      []
    end
  rescue StandardError => e
    Rails.logger.error "MusicBrainz Service Error: #{e.message}"
    []
  end

  private

  def build_work_query(title, artist = nil)
    # work:フィールドを使用せず、直接タイトルで検索
    # これによりより柔軟な検索が可能になる
    query_parts = [ title ]
    query_parts << "AND artist:\"#{escape_query(artist)}\"" if artist.present?
    query_parts.join(" ")
  end

  def escape_query(text)
    # ダブルクオートのみエスケープ
    text.gsub('"', '\"')
  end

  def parse_works_response(response)
    works = response.dig("works") || []
    
    works.map do |work|
      # Work検索APIではRelation情報が不完全なため、詳細APIで再取得
      work_id = work["id"]
      if work_id
        find_work_by_id(work_id)
      else
        Song.new(
          id: work["id"],
          title: work["title"],
          artist: extract_artist_from_work(work),
          type: work["type"],
          composers: extract_composers(work),
          lyricists: extract_lyricists(work)
        )
      end
    end.compact
  end

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

  def extract_artist_from_work(work)
    # WorkのAPIレスポンスではアーティスト情報が限定的
    # そのため、RecordingからアーティストID情報を取得
    relations = work.dig("relations") || []
    work_title = work["title"]
    
    Rails.logger.info "Relations count: #{relations.size}"
    Rails.logger.info "Work title: #{work_title}"
    
    # パフォーマンス関係のレコーディングを取得
    performances = relations.select { |rel| rel["type"] == "performance" }
    
    # カバー、インストゥルメンタル、パーシャルでないオリジナルを優先
    # その中でもタイトルが一致するものを最優先
    best_recording = performances.min_by do |perf|
      attributes = perf["attributes"] || []
      recording_title = perf.dig("recording", "title") || ""
      
      priority = 0
      # オリジナル以外の属性にペナルティを設定
      priority += 100 if attributes.include?("cover")
      priority += 100 if attributes.include?("instrumental")
      priority += 100 if attributes.include?("partial")
      priority += 100 if attributes.include?("live")
      priority += 100 if attributes.include?("karaoke")
      priority += 50 if attributes.include?("medley")
      priority += 50 if attributes.include?("remix")
      priority += 50 if attributes.include?("acoustic")
      
      # 属性がない（オリジナル）場合は最優先
      priority -= 500 if attributes.empty?
      
      # タイトルが完全一致する場合は優先度を上げる
      # 全角・半角の違いを吸収するため正規化して比較
      normalized_work_title = work_title.tr('！', '!').tr('　', ' ')
      normalized_rec_title = recording_title.tr('！', '!').tr('　', ' ')
      priority -= 1000 if normalized_work_title == normalized_rec_title
      
      priority
    end
    
    recording_id = best_recording&.dig("recording", "id")
    
    Rails.logger.info "Selected recording: #{best_recording&.dig('recording', 'title')}" if best_recording
    Rails.logger.info "Recording ID: #{recording_id}"
    
    if recording_id
      # Recording APIから演奏アーティストを取得
      fetch_artist_from_recording(recording_id)
    else
      ""
    end
  end
  
  def fetch_artist_from_recording(recording_id)
    url = "#{BASE_URL}/recording/#{recording_id}"
    Rails.logger.info "Fetching artist from Recording API: #{url}"
    
    response = @client.get(url, {
      query: {
        fmt: "json",
        inc: "artist-credits"
      },
      timeout: 30
    })
    
    Rails.logger.info "Recording API Response: #{response.code}"
    
    if response.success?
      artist_credits = response.parsed_response["artist-credit"] || []
      
      # 複数のアーティストをjoinphraseで結合
      artist_name = artist_credits.map.with_index do |credit, index|
        name = credit["name"] || ""
        joinphrase = credit["joinphrase"] || ""
        "#{name}#{joinphrase}"
      end.join
      
      Rails.logger.info "Artist found: #{artist_name}"
      artist_name
    else
      Rails.logger.error "Recording API failed: #{response.code}"
      ""
    end
  rescue StandardError => e
    Rails.logger.error "Recording API Error: #{e.message}"
    ""
  end

  def search_via_recordings(title, artist = nil)
    query = title
    query += " AND artist:\"#{escape_query(artist)}\"" if artist.present?
    
    url = "#{BASE_URL}/recording"
    Rails.logger.info "Trying recording search: #{url}"
    Rails.logger.info "Recording query: #{query}"
    
    response = @client.get(url, {
      query: {
        query: query,
        fmt: "json",
        inc: "work-rels",
        limit: 10
      },
      timeout: 30
    })
    
    if response.success?
      recordings = response.parsed_response.dig("recordings") || []
      
      # タイトルの完全一致を優先し、カバー版を除外してソート
      sorted_recordings = recordings.sort_by do |recording|
        rec_title = recording["title"] || ""
        relations = recording["relations"] || []
        work_relation = relations.find { |rel| rel["type"] == "performance" }
        attributes = work_relation ? work_relation["attributes"] || [] : []
        
        priority = 0
        # 完全一致でない場合は優先度を下げる
        priority += 1000 unless rec_title.downcase == title.downcase
        # オリジナル以外の属性にペナルティを設定
        priority += 100 if attributes.include?("cover")
        priority += 100 if attributes.include?("instrumental")
        priority += 100 if attributes.include?("live")
        priority += 100 if attributes.include?("karaoke")
        priority += 50 if attributes.include?("medley")
        priority += 50 if attributes.include?("remix")
        priority += 50 if attributes.include?("acoustic")
        priority += 50 if attributes.include?("partial")
        
        # 属性がない（オリジナル）場合は最優先
        priority -= 500 if attributes.empty?
        
        priority
      end
      
      # RecordingからWork情報を取得、Work関連がない場合もRecordingとして返す
      sorted_recordings.map do |recording|
        relations = recording["relations"] || []
        work_relation = relations.find { |rel| rel["type"] == "performance" }
        
        if work_relation
          work_id = work_relation.dig("work", "id")
          if work_id
            # Workが存在する場合はWork情報を取得
            find_work_by_id(work_id)
          else
            # Work IDがない場合はRecordingとして処理
            create_song_from_recording(recording)
          end
        else
          # Work関連がない場合はRecordingとして処理
          create_song_from_recording(recording)
        end
      end.compact
    else
      []
    end
  rescue StandardError => e
    Rails.logger.error "Recording search error: #{e.message}"
    []
  end

  def create_song_from_recording(recording)
    Song.new(
      id: recording["id"],
      title: recording["title"],
      artist: recording.dig("artist-credit", 0, "name") || "",
      type: "Recording",
      composers: [],
      lyricists: []
    )
  end

  def extract_composers(work)
    extract_artists_by_type(work, "composer")
  end

  def extract_lyricists(work)
    extract_artists_by_type(work, "lyricist")
  end

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
