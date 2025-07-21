class MusicBrainzService
  # 環境変数対応でローカル/本番両対応
  BASE_URL = ENV.fetch("MUSICBRAINZ_API_URL", "http://localhost:5000/ws/2")

  def initialize
    @client = HTTParty
  end
end
