module Agentboard
  class Project < ApplicationRecord
    has_many :tickets, dependent: :restrict_with_exception
    has_many :milestones, dependent: :destroy
    has_many :agent_profiles, dependent: :destroy
    has_many :agent_sessions, dependent: :restrict_with_exception
    has_many :workflow_definitions, dependent: :restrict_with_exception
    has_many :approvals, dependent: :restrict_with_exception

    validates :key, presence: true, uniqueness: true, format: { with: /\A[A-Z][A-Z0-9_]{0,15}\z/, message: "must be uppercase letters/digits, e.g. AB" }
    validates :name, :root_path, :default_branch, presence: true

    # Resolves (or bootstraps) the project for the configured repository root.
    def self.current(root: Agentboard.config.root_path)
      find_by(root_path: root.to_s) || first || bootstrap!(root: root)
    end

    def self.bootstrap!(root: Agentboard.config.root_path)
      name = Agentboard.config.dig("project", "name") || File.basename(root.to_s).tr("_-", " ").split.map(&:capitalize).join(" ")
      key = Agentboard.config.dig("project", "key") || derive_key(name)
      branch = Agentboard::Git::Repository.new(root).default_branch rescue "main"
      create!(name: name, key: key, root_path: root.to_s, default_branch: branch || "main")
    rescue ActiveRecord::RecordNotUnique
      find_by!(root_path: root.to_s)
    end

    def self.derive_key(name)
      letters = name.to_s.scan(/[A-Za-z0-9]+/).map { |w| w[0] }.join.upcase
      letters = name.to_s.gsub(/[^A-Za-z]/, "").upcase[0, 3] if letters.length < 2
      letters = "AB" if letters.blank?
      letters = "P#{letters}" unless letters.match?(/\A[A-Z]/)
      letters[0, 6]
    end

    def repository = Agentboard::Git::Repository.new(root_path)

    def next_ticket_number!
      # Atomic counter increment; safe under concurrent creators.
      self.class.where(id: id).update_all("ticket_counter = ticket_counter + 1")
      reload.ticket_counter
    end
  end
end
