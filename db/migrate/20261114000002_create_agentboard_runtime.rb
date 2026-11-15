# Executions, workflows, verification, approvals and evidence (spec §23.1).
class CreateAgentboardRuntime < ActiveRecord::Migration[7.2]
  def change
    create_table :agentboard_workflow_definitions, id: :string, limit: 36 do |t|
      t.references :project, null: false, type: :string, foreign_key: { to_table: :agentboard_projects }
      t.string :name, null: false
      t.integer :version, null: false
      t.json :definition, null: false
      t.text :source_yaml
      t.string :digest, null: false
      t.timestamps
    end
    add_index :agentboard_workflow_definitions, [ :project_id, :name, :version ], unique: true, name: "index_agentboard_workflow_defs_unique"
    add_index :agentboard_workflow_definitions, [ :project_id, :digest ]

    create_table :agentboard_workflow_runs, id: :string, limit: 36 do |t|
      t.references :workflow_definition, null: false, type: :string, foreign_key: { to_table: :agentboard_workflow_definitions }
      t.references :ticket, null: false, type: :string, foreign_key: { to_table: :agentboard_tickets }
      t.string :status, null: false, default: "pending"
      t.string :base_sha
      t.string :worktree_path
      t.string :branch
      t.string :cancel_reason
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :agentboard_workflow_runs, :status

    create_table :agentboard_workflow_steps, id: :string, limit: 36 do |t|
      t.references :workflow_run, null: false, type: :string, foreign_key: { to_table: :agentboard_workflow_runs }
      t.string :step_key, null: false
      t.string :step_type, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempt, null: false, default: 1
      t.json :input, null: false, default: {}
      t.json :output, null: false, default: {}
      t.text :error
      t.datetime :available_at
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :agentboard_workflow_steps, [ :workflow_run_id, :step_key, :attempt ], unique: true, name: "index_agentboard_workflow_steps_unique"

    create_table :agentboard_executions, id: :string, limit: 36 do |t|
      t.references :ticket, null: false, type: :string, foreign_key: { to_table: :agentboard_tickets }
      t.references :agent_profile, type: :string, foreign_key: { to_table: :agentboard_agent_profiles }
      t.references :agent_session, type: :string, foreign_key: { to_table: :agentboard_agent_sessions }
      t.references :workflow_step, type: :string, foreign_key: { to_table: :agentboard_workflow_steps }
      t.string :provider_key, null: false
      t.string :action, null: false, default: "implement"
      t.string :status, null: false, default: "queued"
      t.integer :attempt, null: false, default: 1
      t.string :base_sha
      t.string :head_sha
      t.string :branch
      t.string :worktree_path
      t.string :context_path
      t.string :context_digest
      t.string :log_path
      t.integer :pid
      t.integer :pgid
      t.string :process_fingerprint
      t.string :idempotency_key
      t.integer :exit_code
      t.string :failure_code
      t.text :failure_message
      t.text :summary
      t.string :cancel_reason
      t.datetime :cancel_requested_at
      t.datetime :heartbeat_at
      t.datetime :started_at
      t.datetime :finished_at
      t.bigint :log_bytes, null: false, default: 0
      t.boolean :log_truncated, null: false, default: false
      t.json :metadata, null: false, default: {}
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :agentboard_executions, [ :ticket_id, :created_at ]
    add_index :agentboard_executions, [ :status, :created_at ]
    add_index :agentboard_executions, [ :ticket_id, :attempt ], unique: true
    add_index :agentboard_executions, :idempotency_key, unique: true, where: "idempotency_key IS NOT NULL"

    create_table :agentboard_events, id: :string, limit: 36 do |t|
      t.string :project_id, limit: 36
      t.string :aggregate_type, null: false
      t.string :aggregate_id, null: false
      t.bigint :sequence, null: false
      t.string :event_type, null: false
      t.integer :schema_version, null: false, default: 1
      t.string :source, null: false
      t.string :provenance, null: false, default: "confirmed"
      t.string :ticket_id, limit: 36
      t.string :execution_id, limit: 36
      t.string :session_id, limit: 36
      t.string :actor_type
      t.string :actor_id
      t.string :dedupe_key
      t.datetime :occurred_at, null: false
      t.datetime :received_at, null: false
      t.json :payload, null: false, default: {}
      t.string :correlation_id, null: false
      t.string :causation_id
      t.timestamps
    end
    add_index :agentboard_events, [ :aggregate_type, :aggregate_id, :sequence ], unique: true, name: "index_agentboard_events_aggregate_seq"
    add_index :agentboard_events, [ :project_id, :received_at ]
    add_index :agentboard_events, :correlation_id
    add_index :agentboard_events, [ :ticket_id, :occurred_at ]
    add_index :agentboard_events, [ :execution_id, :sequence ]
    add_index :agentboard_events, :dedupe_key, unique: true, where: "dedupe_key IS NOT NULL"

    create_table :agentboard_outbox_messages, id: :string, limit: 36 do |t|
      t.string :event_id, null: false, limit: 36
      t.string :topic, null: false
      t.string :state, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :available_at, null: false
      t.datetime :delivered_at
      t.text :last_error
      t.timestamps
    end
    add_index :agentboard_outbox_messages, [ :event_id, :topic ], unique: true
    add_index :agentboard_outbox_messages, [ :state, :available_at ]

    create_table :agentboard_artifacts, id: :string, limit: 36 do |t|
      t.references :ticket, null: false, type: :string, foreign_key: { to_table: :agentboard_tickets }
      t.references :execution, type: :string, foreign_key: { to_table: :agentboard_executions }
      t.string :kind, null: false
      t.string :uri, null: false
      t.string :title
      t.string :sha256
      t.string :commit_sha
      t.string :provenance, null: false, default: "confirmed"
      t.json :metadata, null: false, default: {}
      t.timestamps
    end

    create_table :agentboard_verification_results, id: :string, limit: 36 do |t|
      t.references :execution, null: false, type: :string, foreign_key: { to_table: :agentboard_executions }
      t.string :ticket_id, limit: 36
      t.string :name, null: false
      t.string :status, null: false, default: "running"
      t.boolean :required, null: false, default: true
      t.string :command_digest, null: false
      t.string :commit_sha, null: false
      t.integer :exit_code
      t.string :log_artifact_id, limit: 36
      t.text :output_excerpt
      t.float :duration_seconds
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps
    end
    add_index :agentboard_verification_results, [ :execution_id, :commit_sha ]
    add_index :agentboard_verification_results, [ :ticket_id, :commit_sha ]

    create_table :agentboard_approvals, id: :string, limit: 36 do |t|
      t.references :project, null: false, type: :string, foreign_key: { to_table: :agentboard_projects }
      t.string :ticket_id, limit: 36
      t.references :execution, type: :string, foreign_key: { to_table: :agentboard_executions }
      t.string :workflow_step_id, limit: 36
      t.string :action_kind, null: false
      t.string :action_digest, null: false
      t.string :head_sha
      t.json :action_payload, null: false, default: {}
      t.text :reason
      t.string :required_role, null: false, default: "maintainer"
      t.string :requested_by, null: false
      t.string :decision, null: false, default: "pending"
      t.string :decided_by
      t.text :decision_reason
      t.datetime :expires_at
      t.datetime :decided_at
      t.timestamps
    end
    add_index :agentboard_approvals, [ :decision, :expires_at ]
    add_index :agentboard_approvals, :ticket_id

    create_table :agentboard_usage_records, id: :string, limit: 36 do |t|
      t.references :execution, null: false, type: :string, foreign_key: { to_table: :agentboard_executions }
      t.string :provider_key, null: false
      t.string :metering_kind, null: false, default: "unknown"
      t.bigint :input_tokens
      t.bigint :output_tokens
      t.decimal :reported_cost, precision: 12, scale: 6
      t.string :currency
      t.string :source, null: false
      t.timestamps
    end

    create_table :agentboard_idempotency_keys, id: :string, limit: 36 do |t|
      t.string :scope, null: false
      t.string :key, null: false
      t.string :request_digest, null: false
      t.json :response, null: false, default: {}
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :agentboard_idempotency_keys, [ :scope, :key ], unique: true

    create_table :agentboard_repository_snapshots, id: :string, limit: 36 do |t|
      t.references :project, null: false, type: :string, foreign_key: { to_table: :agentboard_projects }
      t.string :commit_sha, null: false
      t.json :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :agentboard_repository_snapshots, [ :project_id, :commit_sha ], unique: true
  end
end
