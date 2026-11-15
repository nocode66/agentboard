Rails.application.routes.draw do
  mount Agentboard::Engine => "/agentboard"
  get "shop", to: "shop#index"
  root to: redirect("/agentboard")
end
