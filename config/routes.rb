Rails.application.routes.draw do
  devise_for :users, skip: [ :passwords ] # パスワードリセット機能を一時的に無効化
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  # Defines the root path route ("/")
  root "home#index"

  # Song search routes
  resources :songs, only: [ :index, :show ] do
    collection do
      get :search
      get :artist_works
      get :load_artists  # アーティスト情報の非同期読み込み用
      get :youtube_search  # YouTube動画検索用
    end
  end
end
