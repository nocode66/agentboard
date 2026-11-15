# AgentBoard core schema (spec §23.1).
#
# Primary keys are application-generated UUIDv7 strings so the same schema works on
# PostgreSQL and SQLite without extensions. Every table is prefixed `agentboard_`.
class CreateAgentboardCore < ActiveRecord::Migration[7.2]
  def change
    create_table :agentboard_projects, id: :string, limit: 36 do |t|
      t.string :key, null: false, limit: 16
      t.string :name, null: false
      t.string :root_path, null: false
      t.string :repository_url
      t.string :default_branch, null: false, default: "main"
      t.json :settings, null: false, default: {}
      t.integer :ticket_counter, null: false, default: 0
      t.timestamps
    end
    add_index :agentboard_projects, :key, unique: true
    add_index :agentboard_projects, :root_path, unique: true

    create_table :agentboard_milestones, id: :string, limit: 36 do |t|
      t.references :project, null: false, type: :string, foreign_key: { to_table: :agentboard_projects }
      t.string :name, null: false
      t.date :target_date
      t.string :status, null: false, default: "open"
      t.timestamps
    end

    create_table :agentboard_tickets, id: :string, limit: 36 do |t|
      t.references :project, null: false, type: :string, foreign_key: { to_table: :agentboard_projects }
      t.references :milestone, type: :string, foreign_key: { to_table: :agentboard_milestones }
      t.references :parent, type: :string, foreign_key: { to_table: :agentboard_tickets }
      t.integer :number, null: false
      t.string :title, null: false, limit: 255
      t.text :description, null: false, default: ""
      t.string :kind, null: false, default: "task"
      t.string :status, null: false, default: "backlog"
      t.integer :priority, null: false, default: 2
      t.float :position, null: false, default: 0
      t.json :labels, null: false, default: []
      t.string :assignee_profile_id, limit: 36
      t.string :created_by_id
      t.text :blocked_reason
      t.bigint :fencing_counter, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.datetime :completed_at
      t.timestamps
    end
    add_index :agentboard_tickets, [ :project_id, :number ], unique: true
    add_index :agentboard_tickets, [ :project_id, :status, :priority ]

    create_table :agentboard_ticket_dependencies, id: :string, limit: 36 do |t|
      t.references :ticket, null: false, type: :string, foreign_key: { to_table: :agentboard_tickets }
      t.references :depends_on_ticket, null: false, type: :string, foreign_key: { to_table: :agentboard_tickets }
      t.string :kind, null: false, default: "blocks"
      t.timestamps
    end
    add_index :agentboard_ticket_dependencies, [ :ticket_id, :depends_on_ticket_id, :kind ], unique: true, name: "index_agentboard_ticket_deps_unique"
    add_check_constraint :agentboard_ticket_dependencies, "ticket_id <> depends_on_ticket_id", name: "agentboard_no_self_dependency"

    create_table :agentboard_acceptance_criteria, id: :string, limit: 36 do |t|
      t.references :ticket, null: false, type: :string, foreign_key: { to_table: :agentboard_tickets }
      t.integer :position, null: false
      t.text :description, null: false
      t.string :verification_kind, null: false, default: "manual"
      t.string :state, null: false, default: "pending"
      t.string :evidence_id, limit: 36
      t.string :verified_by
      t.datetime :verified_at
      t.timestamps
    end
    add_index :agentboard_acceptance_criteria, [ :ticket_id, :position ], unique: true

    create_table :agentboard_comments, id: :string, limit: 36 do |t|
      t.references :ticket, null: false, type: :string, foreign_key: { to_table: :agentboard_tickets }
      t.string :actor_type, null: false
      t.string :actor_id, null: false
      t.string :actor_name
      t.string :visibility, null: false, default: "team"
      t.text :body, null: false
      t.timestamps
    end
    add_index :agentboard_comments, [ :ticket_id, :created_at ]

    create_table :agentboard_agent_profiles, id: :string, limit: 36 do |t|
      t.references :project, null: false, type: :string, foreign_key: { to_table: :agentboard_projects }
      t.string :provider_key, null: false
      t.string :name, null: false
      t.string :model
      t.json :config, null: false, default: {}
      t.json :permissions, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :agentboard_agent_profiles, [ :project_id, :name ], unique: true

    create_table :agentboard_agent_sessions, id: :string, limit: 36 do |t|
      t.references :project, null: false, type: :string, foreign_key: { to_table: :agentboard_projects }
      t.string :provider_key, null: false
      t.string :external_session_id
      t.string :state, null: false, default: "active"
      t.string :trust_level, null: false, default: "untrusted"
      t.string :label
      t.string :credential_digest
      t.string :cwd
      t.json :metadata, null: false, default: {}
      t.datetime :last_seen_at
      t.datetime :ended_at
      t.timestamps
    end
    add_index :agentboard_agent_sessions, [ :project_id, :provider_key, :external_session_id ], unique: true,
              where: "external_session_id IS NOT NULL", name: "index_agentboard_sessions_external_unique"
    add_index :agentboard_agent_sessions, :credential_digest, unique: true, where: "credential_digest IS NOT NULL"

    create_table :agentboard_session_ticket_links, id: :string, limit: 36 do |t|
      t.references :agent_session, null: false, type: :string, foreign_key: { to_table: :agentboard_agent_sessions }
      t.references :ticket, null: false, type: :string, foreign_key: { to_table: :agentboard_tickets }
      t.datetime :started_at, null: false
      t.datetime :ended_at
      t.string :source, null: false
      t.string :confidence, null: false, default: "confirmed"
      t.timestamps
    end
    add_index :agentboard_session_ticket_links, [ :agent_session_id, :ended_at ]
    add_index :agentboard_session_ticket_links, :agent_session_id, unique: true, where: "ended_at IS NULL",
              name: "index_agentboard_session_links_one_active"

    create_table :agentboard_ticket_leases, id: :string, limit: 36 do |t|
      t.references :ticket, null: false, type: :string, foreign_key: { to_table: :agentboard_tickets }
      t.references :agent_session, type: :string, foreign_key: { to_table: :agentboard_agent_sessions }
      t.string :holder_label
      t.string :token_digest, null: false
      t.bigint :fencing_token, null: false
      t.datetime :expires_at, null: false
      t.datetime :released_at
      t.string :release_reason
      t.timestamps
    end
    # Database-enforced exclusivity: at most one unreleased lease per ticket.
    add_index :agentboard_ticket_leases, :ticket_id, unique: true, where: "released_at IS NULL",
              name: "index_agentboard_leases_one_live_per_ticket"
    add_index :agentboard_ticket_leases, :expires_at
    add_index :agentboard_ticket_leases, :token_digest, unique: true
  end
end
