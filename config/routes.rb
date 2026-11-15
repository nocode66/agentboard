Agentboard::Engine.routes.draw do
  root to: "board#show"

  get "board", to: "board#show", as: :board
  get "pulse", to: "pulse#show", as: :pulse
  get "assets/:name", to: "assets#show", as: :engine_asset, constraints: { name: /[a-z]+\.(css|js)/ }

  resources :tickets, param: :key, constraints: { key: /[A-Z][A-Z0-9_-]*-\d+/ } do
    member do
      post :transition
      post :move
      post :verify
      post :run
      post :complete
      post :link_pr
      get :suggestions
      post :accept_suggestion
    end
    resources :comments, only: :create
    resources :criteria, only: %i[create update], controller: "criteria"
    resources :dependencies, only: %i[create destroy]
  end

  resources :executions, only: %i[index show] do
    member do
      post :cancel
      post :retry
      post :resume
      get :log
    end
  end

  resources :milestones, only: %i[index create update]
  resources :captures, only: :create do
    member { get :screenshot }
  end
  resources :approvals, only: %i[index update]
  resources :workflows, only: %i[index show create] do
    collection { post :validate }
    member { post :start }
  end
  resources :workflow_runs, only: :show do
    member { post :cancel }
  end
  resources :sessions, only: :update
  get "agents", to: "agents#index", as: :agents
  get "analytics", to: "analytics#show", as: :analytics
  get "settings", to: "settings#show", as: :settings
end
