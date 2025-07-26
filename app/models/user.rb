class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         # :recoverable, # パスワードリセット機能を一時的にコメントアウト
         :rememberable, :validatable

  validates :username, presence: true, uniqueness: { case_sensitive: false }
  validates :username, length: { minimum: 2, maximum: 30 }

  def display_name
    username.presence || email.split("@").first
  end
end
