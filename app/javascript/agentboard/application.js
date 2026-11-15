// AgentBoard dashboard behaviour. Loaded as an ES module through an import map that points
// at the Turbo and Stimulus builds shipped inside their gems (no Node, no bundler).
// turbo-rails' ESM build exports { Turbo, cable } (not individual functions).
import { Turbo } from "@hotwired/turbo"
import { Application, Controller } from "@hotwired/stimulus"

const application = Application.start()
window.Stimulus = application

const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content

async function postJSON(url, body) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrfToken() },
    body: JSON.stringify(body),
    credentials: "same-origin"
  })
  const data = await response.json().catch(() => ({}))
  return { ok: response.ok && data.ok !== false, data }
}

function toast(message, kind = "alert") {
  const host = document.querySelector(".toasts")
  if (!host) return
  const el = document.createElement("div")
  el.className = `toast toast-${kind}`
  el.setAttribute("data-controller", "toast")
  el.innerHTML = `<span>${kind === "alert" ? "⚠︎" : "✓"}</span><div></div>`
  el.querySelector("div").textContent = message
  host.appendChild(el)
}

function refresh() {
  // Don't yank the page while the user is typing or has a dialog open.
  const active = document.activeElement
  if (document.querySelector("dialog[open], details.popover[open]")) return
  if (active && ["TEXTAREA", "INPUT", "SELECT"].includes(active.tagName) && active.value) return
  // Turbo 8 page refresh: morphs the current page in place and preserves scroll.
  if (Turbo.session?.refresh) Turbo.session.refresh(window.location.href)
  else Turbo.visit(window.location.href, { action: "replace" })
}

// Live updates: poll the event cursor and morph-refresh when something changed.
application.register("pulse", class extends Controller {
  static values = { url: String, interval: { type: Number, default: 3000 } }
  connect() {
    this.cursor = undefined
    this.timer = setInterval(() => this.check(), this.intervalValue)
    this.onVisibility = () => document.visibilityState === "visible" && this.check()
    document.addEventListener("visibilitychange", this.onVisibility)
  }
  disconnect() { clearInterval(this.timer); document.removeEventListener("visibilitychange", this.onVisibility) }
  async check() {
    if (document.visibilityState !== "visible") return
    try {
      const res = await fetch(this.urlValue, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!res.ok) return
      const data = await res.json()
      const live = document.getElementById("runtime-active")
      if (live) live.textContent = data.active_executions
      const changed = this.cursor !== undefined && data.cursor !== this.cursor
      this.cursor = data.cursor
      if (changed && !document.querySelector(".tcard.is-dragging")) refresh()
    } catch (error) {
      console.warn("[agentboard] live update failed", error)
    }
  }
})

// Kanban drag & drop. Transitions are validated server-side; invalid drops revert.
application.register("board", class extends Controller {
  static values = { moveUrl: String }
  connect() {
    this.element.addEventListener("dragstart", this.start)
    this.element.addEventListener("dragend", this.end)
    this.element.querySelectorAll("[data-column]").forEach((col) => {
      col.addEventListener("dragover", this.over)
      col.addEventListener("dragleave", this.leave)
      col.addEventListener("drop", this.drop)
    })
  }
  start = (e) => {
    const card = e.target.closest(".tcard")
    if (!card) return
    this.dragged = card
    card.classList.add("is-dragging")
    e.dataTransfer.effectAllowed = "move"
    e.dataTransfer.setData("text/plain", card.dataset.key)
    const allowed = (card.dataset.allowed || "").split(" ")
    this.element.querySelectorAll("[data-column]").forEach((col) => {
      if (col.dataset.column !== card.dataset.status && !allowed.includes(col.dataset.column)) col.classList.add("is-invalid")
    })
  }
  end = () => {
    this.dragged?.classList.remove("is-dragging")
    this.element.querySelectorAll(".is-over, .is-invalid").forEach((c) => c.classList.remove("is-over", "is-invalid"))
  }
  over = (e) => {
    e.preventDefault()
    const col = e.currentTarget
    col.classList.add("is-over")
    const body = col.querySelector(".column-body")
    const after = [...body.querySelectorAll(".tcard:not(.is-dragging)")].find((c) => e.clientY < c.getBoundingClientRect().top + c.offsetHeight / 2)
    if (this.dragged) after ? body.insertBefore(this.dragged, after) : body.appendChild(this.dragged)
  }
  leave = (e) => { if (!e.currentTarget.contains(e.relatedTarget)) e.currentTarget.classList.remove("is-over") }
  drop = async (e) => {
    e.preventDefault()
    const card = this.dragged
    const col = e.currentTarget
    col.classList.remove("is-over")
    if (!card) return
    const to = col.dataset.column
    const prev = card.previousElementSibling?.dataset.position
    const next = card.nextElementSibling?.dataset.position
    let position
    if (prev && next) position = (parseFloat(prev) + parseFloat(next)) / 2
    else if (prev) position = parseFloat(prev) + 1
    else if (next) position = parseFloat(next) - 1
    let reason
    if (to === "blocked" || to === "cancelled") {
      reason = prompt(`Reason for ${to}?`)
      if (!reason) return refresh()
    }
    const url = card.dataset.moveUrl
    const { ok, data } = await postJSON(url, { to, position, reason })
    if (!ok) toast(data?.error?.message || "Move rejected")
    refresh()
  }
})

// Execution console: tails the redacted log while the execution is active.
application.register("log", class extends Controller {
  static values = { url: String, active: Boolean }
  static targets = ["body"]
  connect() { this.load(); if (this.activeValue) this.timer = setInterval(() => this.load(), 1500) }
  disconnect() { clearInterval(this.timer) }
  async load() {
    const res = await fetch(this.urlValue, { credentials: "same-origin" })
    if (!res.ok) return
    const text = await res.text()
    const body = this.bodyTarget
    const atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 40
    if (body.textContent !== text) {
      body.textContent = text
      if (atBottom) body.scrollTop = body.scrollHeight
    }
  }
})

application.register("theme", class extends Controller {
  connect() { this.apply(localStorage.getItem("agentboard-theme")) }
  toggle() {
    const current = document.documentElement.dataset.theme ||
      (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light")
    const next = current === "dark" ? "light" : "dark"
    localStorage.setItem("agentboard-theme", next)
    this.apply(next)
  }
  apply(theme) { if (theme) document.documentElement.dataset.theme = theme }
})

application.register("toast", class extends Controller {
  connect() { this.timer = setTimeout(() => this.dismiss(), this.element.classList.contains("toast-alert") ? 9000 : 4500) }
  disconnect() { clearTimeout(this.timer) }
  dismiss() { this.element.classList.add("is-leaving"); setTimeout(() => this.element.remove(), 200) }
})

application.register("modal", class extends Controller {
  static values = { id: String }
  open(e) { e?.preventDefault(); document.getElementById(this.idValue)?.showModal(); document.getElementById(this.idValue)?.querySelector("[autofocus]")?.focus() }
  close(e) { e?.preventDefault(); this.element.closest("dialog")?.close() }
})

// Live YAML validation for the workflow editor.
application.register("workflow-validator", class extends Controller {
  static values = { url: String }
  static targets = ["input", "output"]
  connect() { this.validate() }
  schedule() { clearTimeout(this.timer); this.timer = setTimeout(() => this.validate(), 350) }
  async validate() {
    const { data } = await postJSON(this.urlValue, { yaml: this.inputTarget.value })
    const out = this.outputTarget
    if (data.ok) {
      out.className = "validator ok"
      out.textContent = `✓ ${data.name} — valid DAG: ${data.steps.join(" → ")}`
    } else {
      out.className = "validator bad"
      out.textContent = "✗ " + (data.errors || ["invalid"]).join("\n✗ ")
    }
  }
  indent(e) {
    if (e.key !== "Tab") return
    e.preventDefault()
    const t = e.target, s = t.selectionStart
    t.setRangeText("  ", s, t.selectionEnd, "end")
    this.schedule()
  }
})

// Keyboard shortcuts: c = new ticket, / = search, g b / g e / g a = navigation.
application.register("hotkeys", class extends Controller {
  connect() { this.onKey = (e) => this.handle(e); document.addEventListener("keydown", this.onKey) }
  disconnect() { document.removeEventListener("keydown", this.onKey) }
  handle(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return
    const tag = (e.target.tagName || "").toLowerCase()
    if (["input", "textarea", "select"].includes(tag) || e.target.isContentEditable) return
    const link = (sel) => document.querySelector(sel)?.click()
    if (this.pendingG) {
      this.pendingG = false
      const map = { b: "board", l: "backlog", e: "executions", a: "agents", w: "workflows", r: "approvals" }
      if (map[e.key]) { e.preventDefault(); link(`[data-hotkey-target="${map[e.key]}"]`) }
      return
    }
    if (e.key === "g") { this.pendingG = true; setTimeout(() => (this.pendingG = false), 800); return }
    if (e.key === "c") { e.preventDefault(); link("[data-hotkey='new-ticket']") }
    if (e.key === "/") { e.preventDefault(); document.querySelector("[data-hotkey='search']")?.focus() }
  }
})

application.register("autosubmit", class extends Controller {
  submit() { clearTimeout(this.t); this.t = setTimeout(() => this.element.requestSubmit(), 250) }
})

export { Turbo, application }
