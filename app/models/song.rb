class Song
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :id, :string
  attribute :title, :string
  attribute :artist, :string
  attribute :type, :string
  attribute :composers, default: -> { [] }
  attribute :lyricists, default: -> { [] }
  attribute :loading_artist, :boolean, default: false

  def same_creator?
    return false if composers.empty? || lyricists.empty?
    composer_names = composers.map { |c| c.is_a?(Hash) ? c[:name] : c }.compact
    lyricist_names = lyricists.map { |l| l.is_a?(Hash) ? l[:name] : l }.compact
    composer_names.sort == lyricist_names.sort
  end

  def all_creators
    (composers + lyricists).uniq { |creator|
      creator.is_a?(Hash) ? creator[:name] : creator
    }
  end

  def creator_names
    lyricist_names = lyricists.map { |l| l.is_a?(Hash) ? l[:name] : l }.compact
    composer_names = composers.map { |c| c.is_a?(Hash) ? c[:name] : c }.compact

    # 作詞作曲が同じ場合
    if same_creator?
      "作詞作曲:#{composer_names.join(', ')}"
    else
      # 作詞作曲が異なる場合
      parts = []
      parts << "作詞:#{lyricist_names.join(', ')}" if lyricist_names.any?
      parts << "作曲:#{composer_names.join(', ')}" if composer_names.any?
      parts.join("/")
    end
  end
end
