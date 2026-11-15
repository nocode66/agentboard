namespace :agentboard do
  desc "Drain the event outbox once"
  task drain_outbox: :environment do
    puts "delivered #{Agentboard::Outbox.drain(limit: 1000)}"
  end
end
