# v0.2: Git provider webhooks (spec §29.3). Deliveries are recorded for idempotency and audit,
# including rejected (forged) ones. Raw payloads are never stored — only a digest.
class CreateAgentboardWebhookDeliveries < ActiveRecord::Migration[7.2]
  def change
    create_table :agentboard_webhook_deliveries, id: :string, limit: 36 do |t|
      t.string :provider, null: false
      t.string :delivery_id, null: false
      t.string :event, null: false
      t.boolean :signature_valid, null: false, default: false
      t.string :payload_digest, null: false
      t.string :status, null: false, default: "received"
      t.text :detail
      t.timestamps
    end
    add_index :agentboard_webhook_deliveries, [ :provider, :delivery_id ], unique: true, name: "index_agentboard_webhook_deliveries_unique"
    add_index :agentboard_webhook_deliveries, :created_at
  end
end
