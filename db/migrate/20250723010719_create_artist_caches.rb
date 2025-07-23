class CreateArtistCaches < ActiveRecord::Migration[7.2]
  def change
    create_table :artist_caches do |t|
      t.string :work_id, null: false, limit: 36
      t.string :artist_name, limit: 500
      t.datetime :cached_at, null: false
      t.integer :access_count, default: 0, null: false
      t.datetime :last_accessed_at

      t.timestamps
    end

    add_index :artist_caches, :work_id, unique: true
    add_index :artist_caches, :cached_at
    add_index :artist_caches, :access_count
  end
end
