module Agentboard
  # Resolves the code state a ticket is currently judged against, and records evidence
  # artifacts with explicit provenance.
  module Evidence
    module_function

    # The head commit is the most recent *verified-in-repo* commit evidence: execution head
    # or attached commit artifact. Agent-claimed SHAs that aren't in the repository don't count.
    def head_sha(ticket)
      candidates = []
      ticket.executions.where.not(head_sha: nil).where.not(action: "verify").limit(5).each { |e| candidates << [ e.finished_at || e.updated_at, e.head_sha ] }
      ticket.artifacts.where(kind: "commit").limit(20).select { |a| a.metadata["verified_in_repo"] }.each { |a| candidates << [ a.created_at, a.commit_sha ] }
      candidates.compact.max_by { |(t, _)| t.to_f }&.last
    end

    def attach_commit!(ticket:, commit_sha:, actor:, execution: nil, provenance: nil, session: nil)
      sha = commit_sha.to_s.strip.downcase
      raise Error.validation_failed("commit_sha must be a 7-64 character hex string") unless sha.match?(/\A[0-9a-f]{7,64}\z/)

      repo = ticket.project.repository
      full = repo.resolve_commit(sha)
      verified = full.present?
      Artifact.transaction do
        artifact = ticket.artifacts.create!(
          execution: execution, kind: "commit", uri: "git:#{full || sha}", commit_sha: full || sha, title: (verified ? repo.commit_subject(full) : nil),
          provenance: provenance || (verified ? "git_observed" : (actor.agent? ? "provider_reported" : "confirmed")),
          metadata: { verified_in_repo: verified, attached_by: actor.label }
        )
        EventStore.append!(type: "git.commit_attached", aggregate: ticket, ticket: ticket, actor: actor, session: session,
                           provenance: artifact.provenance, payload: { artifact_id: artifact.id, commit_sha: artifact.commit_sha, verified_in_repo: verified })
        artifact
      end
    end

    def attach_artifact!(ticket:, actor:, kind:, uri:, title: nil, metadata: {}, execution: nil, session: nil)
      raise Error.validation_failed("Unknown artifact kind #{kind}") unless Artifact::KINDS.include?(kind.to_s)
      raise Error.validation_failed("Artifacts of kind commit must use attach_commit") if kind.to_s == "commit"
      if uri.to_s.match?(/\A(?:javascript|data):/i)
        raise Error.validation_failed("Unsupported URI scheme")
      end

      Artifact.transaction do
        artifact = ticket.artifacts.create!(execution: execution, kind: kind, uri: uri.to_s[0, 2000], title: title&.to_s&.[](0, 255),
                                            provenance: actor.agent? ? "provider_reported" : "confirmed",
                                            metadata: Redactor.redact_value(metadata.to_h))
        EventStore.append!(type: "ticket.artifact_attached", aggregate: ticket, ticket: ticket, actor: actor, session: session,
                           provenance: artifact.provenance, payload: { artifact_id: artifact.id, kind: kind, uri: artifact.uri })
        artifact
      end
    end
  end
end
