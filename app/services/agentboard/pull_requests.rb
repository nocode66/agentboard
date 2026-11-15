module Agentboard
  # Pull request evidence shared by the core (manual links) and Pro (GitHub webhooks).
  module PullRequests
    module_function

    def upsert!(ticket, pr:, state:, head_ref:, head_sha:, match:, merge_verified:, source:)
      url = pr["html_url"].to_s
      artifact = ticket.artifacts.where(kind: "pull_request").find { |a| a.uri == url } ||
                 ticket.artifacts.new(kind: "pull_request", uri: url)
      artifact.assign_attributes(
        title: "PR ##{pr["number"]}: #{pr["title"].to_s[0, 200]}", commit_sha: head_sha.presence,
        provenance: match == "branch_name" ? "inferred" : "git_observed",
        metadata: artifact.metadata.to_h.merge(
          "number" => pr["number"], "state" => state, "head_ref" => head_ref, "head_sha" => head_sha,
          "base_ref" => pr.dig("base", "ref"), "merge_commit_sha" => pr["merge_commit_sha"], "merged_at" => pr["merged_at"],
          "merge_verified" => merge_verified, "match" => match, "source" => source
        )
      )
      artifact.save!
      EventStore.append!(type: "git.pull_request_#{state}", aggregate: ticket, ticket: ticket, source: "#{source}.github",
                         provenance: artifact.provenance,
                         payload: { number: pr["number"], url: url, head_sha: head_sha, match: match, merge_commit_sha: pr["merge_commit_sha"] })
      artifact
    end

    def attempt_completion!(ticket)
      return unless ticket.reload.status == "review"

      report = CompletionPolicy.evaluate(ticket)
      if report[:ok]
        Tickets.transition!(ticket: ticket, to: "done", actor: Authorization.system_actor)
      else
        EventStore.append!(type: "ticket.completion_blocked", aggregate: ticket, ticket: ticket, source: "pull_request",
                           payload: { missing: report[:missing] })
      end
    end

    # Manual PR link (core feature, works without GitHub). A merge counts as verified only if
    # the merge commit exists locally and contains the ticket's reviewed head.
    def link_manually!(ticket:, actor:, url:, state:, merge_commit_sha: nil)
      Authorization.authorize!(actor, "ticket.write")
      raise Error.validation_failed("PR URL must be http(s)") unless url.to_s.match?(%r{\Ahttps?://\S+\z})
      raise Error.validation_failed("State must be open, closed or merged") unless %w[open closed merged].include?(state)

      head = Evidence.head_sha(ticket)
      verified = false
      if state == "merged"
        raise Error.forbidden("Only maintainers can record a merge") unless Authorization.allowed?(actor, "ticket.complete")

        repo = ticket.project.repository
        full = repo.resolve_commit(merge_commit_sha.to_s)
        raise Error.validation_failed("Merge commit #{merge_commit_sha} is not in the local repository (git fetch first)") unless full
        raise Error.policy_denied("Merge commit does not contain the reviewed head #{head.to_s[0, 10]}") unless head && repo.ancestor?(head, full)

        merge_commit_sha = full
        verified = true
      end
      pr = { "html_url" => url, "number" => url[%r{/pull/(\d+)}, 1]&.to_i, "title" => "external", "merge_commit_sha" => merge_commit_sha }
      artifact = upsert!(ticket, pr: pr, state: state, head_ref: nil, head_sha: head.to_s, match: "manual", merge_verified: verified, source: "manual")
      artifact.update!(provenance: "confirmed")
      attempt_completion!(ticket) if verified
      artifact
    end
  end
end
