# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2025_07_23_010719) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "artist_caches", force: :cascade do |t|
    t.string "work_id", limit: 36, null: false
    t.string "artist_name", limit: 500
    t.datetime "cached_at", null: false
    t.integer "access_count", default: 0, null: false
    t.datetime "last_accessed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["access_count"], name: "index_artist_caches_on_access_count"
    t.index ["cached_at"], name: "index_artist_caches_on_cached_at"
    t.index ["work_id"], name: "index_artist_caches_on_work_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["username"], name: "index_users_on_username", unique: true
  end
end
