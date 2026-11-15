// AgentBoard capture widget — injected into the host app's pages by Agentboard::Capture::Middleware.
// Select elements on any screen and turn them into an AgentBoard ticket. No dependencies.
// Everything lives in a closed Shadow DOM so the host app's CSS and ours never collide.
(() => {
  if (window.__agentboardCapture) return
  window.__agentboardCapture = true
  const script = document.currentScript
  const cfg = JSON.parse(script?.dataset.agentboardCapture || "{}")
  const consoleErrors = []

  // --- console error collection (messages only, capped) ----------------------------------
  const push = (msg) => { consoleErrors.push(String(msg).slice(0, 500)); if (consoleErrors.length > 20) consoleErrors.shift() }
  const origError = console.error
  console.error = function (...args) { push(args.map(a => (a && a.message) || a).join(" ")); return origError.apply(this, args) }
  window.addEventListener("error", e => push(`${e.message} @ ${e.filename || ""}:${e.lineno || ""}`))
  window.addEventListener("unhandledrejection", e => push(`Unhandled rejection: ${e.reason && (e.reason.message || e.reason)}`))

  // --- helpers ----------------------------------------------------------------------------
  const cssEscape = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^\w-]/g, "\\$&")
  function selectorFor(el) {
    if (el.id) return `#${cssEscape(el.id)}`
    const parts = []
    let node = el
    while (node && node.nodeType === 1 && parts.length < 5 && node !== document.body) {
      const testid = node.getAttribute("data-testid") || node.getAttribute("data-test")
      if (testid) { parts.unshift(`[data-testid="${testid}"]`); break }
      if (node.id) { parts.unshift(`#${cssEscape(node.id)}`); break }
      let part = node.tagName.toLowerCase()
      const cls = [...node.classList].filter(c => !/^(is-|has-|active|hover|focus|ab-)/.test(c)).slice(0, 2)
      if (cls.length) part += "." + cls.map(cssEscape).join(".")
      const same = node.parentElement ? [...node.parentElement.children].filter(c => c.tagName === node.tagName) : []
      if (same.length > 1) part += `:nth-of-type(${same.indexOf(node) + 1})`
      parts.unshift(part)
      node = node.parentElement
    }
    return parts.join(" > ")
  }

  // Rails' annotate_rendered_view_with_filenames wraps each template in
  // <!-- BEGIN app/views/x.html.erb --> … <!-- END app/views/x.html.erb -->. Walk backwards
  // through siblings and ancestors; the first BEGIN without a matching END encloses `el`.
  function templateFor(el) {
    const closed = new Set()
    let node = el
    while (node && node !== document) {
      let sib = node.previousSibling
      while (sib) {
        if (sib.nodeType === 8) {
          const text = sib.nodeValue.trim()
          if (text.startsWith("END ")) closed.add(text.slice(4))
          else if (text.startsWith("BEGIN ")) { const path = text.slice(6); if (!closed.has(path)) return path }
        }
        sib = sib.previousSibling
      }
      node = node.parentNode
    }
    return null
  }

  function htmlSnippet(el) {
    const clone = el.cloneNode(true)
    clone.querySelectorAll?.("input, textarea, select").forEach(i => { i.removeAttribute("value"); if (i.tagName === "TEXTAREA") i.textContent = "" })
    if (clone.tagName === "INPUT") clone.removeAttribute("value")
    return clone.outerHTML.slice(0, 2000)
  }

  const describe = (el) => {
    const r = el.getBoundingClientRect()
    return { el, selector: selectorFor(el), template: templateFor(el), text: (el.innerText || "").trim().slice(0, 300),
             html: htmlSnippet(el), rect: { x: r.x + scrollX, y: r.y + scrollY, width: r.width, height: r.height } }
  }

  // --- UI ---------------------------------------------------------------------------------
  const host = document.createElement("div")
  host.setAttribute("data-agentboard-capture-root", "")
  document.documentElement.appendChild(host)
  const root = host.attachShadow({ mode: "closed" })
  root.innerHTML = `
  <style>
    :host { all: initial; }
    * { box-sizing: border-box; font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    .fab { position: fixed; right: 20px; bottom: 20px; z-index: 2147483646; display: flex; align-items: center; gap: 8px; height: 42px; padding: 0 16px 0 12px;
      border: 0; border-radius: 21px; cursor: pointer; color: #fff; font-size: 13.5px; font-weight: 650;
      background: linear-gradient(120deg,#6d6aff,#a855f7 55%,#ec4899); box-shadow: 0 10px 30px rgba(109,106,255,.45), 0 0 0 1px rgba(255,255,255,.15) inset; }
    .fab:hover { filter: brightness(1.08); }
    .fab kbd { font-size: 10.5px; opacity: .8; border: 1px solid rgba(255,255,255,.4); border-radius: 4px; padding: 0 4px; }
    .mark { width: 18px; height: 18px; border-radius: 5px; background: rgba(255,255,255,.25); display: grid; place-items: center; }
    .hl { position: absolute; z-index: 2147483645; pointer-events: none; border: 2px solid #7c7aff; background: rgba(124,122,255,.12); border-radius: 4px; transition: all .06s; }
    .hl.sel { border-color: #ec4899; background: rgba(236,72,153,.12); }
    .hl .lbl { position: absolute; left: -2px; top: -24px; white-space: nowrap; font-size: 11px; font-weight: 600; color: #fff; background: #7c7aff; padding: 3px 7px; border-radius: 5px; font-family: ui-monospace, Menlo, monospace; }
    .hl.sel .lbl { background: #ec4899; }
    .bar { position: fixed; top: 16px; left: 50%; transform: translateX(-50%); z-index: 2147483646; display: flex; gap: 10px; align-items: center; padding: 8px 10px 8px 14px;
      border-radius: 12px; background: #111118; color: #ededf2; font-size: 13px; box-shadow: 0 12px 40px rgba(0,0,0,.4); border: 1px solid #2a2a35; }
    .btn { height: 32px; padding: 0 12px; border-radius: 8px; border: 1px solid #33333f; background: #1b1b24; color: #ededf2; font-size: 13px; font-weight: 600; cursor: pointer; }
    .btn:hover { background: #24242f; }
    .btn.primary { border: 0; color: #fff; background: linear-gradient(120deg,#6d6aff,#a855f7); }
    .btn[disabled] { opacity: .5; cursor: default; }
    .panel { position: fixed; top: 0; right: 0; bottom: 0; width: min(420px, 100vw); z-index: 2147483647; background: #101016; color: #ededf2; border-left: 1px solid #262630;
      box-shadow: -20px 0 60px rgba(0,0,0,.45); display: flex; flex-direction: column; animation: slide .22s cubic-bezier(.2,.8,.2,1); }
    @keyframes slide { from { transform: translateX(30px); opacity: 0 } }
    .ph { display: flex; align-items: center; gap: 10px; padding: 16px 18px; border-bottom: 1px solid #262630; font-weight: 700; font-size: 15px; }
    .ph .x { margin-left: auto; background: none; border: 0; color: #8d8d9c; font-size: 20px; cursor: pointer; }
    .pb { padding: 16px 18px; overflow: auto; flex: 1; display: grid; gap: 14px; align-content: start; }
    label { display: grid; gap: 6px; font-size: 12px; font-weight: 600; color: #a9a9b8; }
    input, textarea, select { width: 100%; font-size: 14px; color: #ededf2; background: #17171f; border: 1px solid #2f2f3b; border-radius: 9px; padding: 9px 11px; }
    textarea { min-height: 84px; resize: vertical; }
    input:focus, textarea:focus, select:focus { outline: none; border-color: #7c7aff; box-shadow: 0 0 0 3px rgba(124,122,255,.25); }
    .seg { display: flex; gap: 6px; }
    .seg button { flex: 1; height: 32px; border-radius: 8px; border: 1px solid #2f2f3b; background: #17171f; color: #a9a9b8; font-size: 13px; font-weight: 600; cursor: pointer; }
    .seg button.on { border-color: #7c7aff; color: #fff; background: rgba(124,122,255,.18); }
    .chips { display: grid; gap: 8px; }
    .chip { display: grid; grid-template-columns: 1fr auto; gap: 4px 8px; padding: 9px 10px; border-radius: 9px; background: #17171f; border: 1px solid #2a2a35; font-size: 12px; }
    .chip code { font-family: ui-monospace, Menlo, monospace; color: #c4c3ff; word-break: break-all; }
    .chip .tpl { grid-column: 1 / -1; color: #86efac; font-family: ui-monospace, Menlo, monospace; font-size: 11.5px; }
    .chip .rm { background: none; border: 0; color: #8d8d9c; cursor: pointer; font-size: 15px; }
    .meta { font-size: 12px; color: #8d8d9c; line-height: 1.6; }
    .meta code { color: #c9c9d3; font-family: ui-monospace, Menlo, monospace; }
    .check { display: flex; align-items: center; gap: 8px; font-size: 13px; color: #c9c9d3; font-weight: 500; }
    .check input { width: auto; }
    .shot { width: 100%; border-radius: 9px; border: 1px solid #2a2a35; }
    .pro { font-size: 10px; font-weight: 800; padding: 1px 6px; border-radius: 5px; background: rgba(245,158,11,.18); color: #fbbf24; }
    .pf { padding: 14px 18px; border-top: 1px solid #262630; display: flex; gap: 10px; }
    .pf .btn { flex: 1; height: 40px; }
    .toast { position: fixed; right: 20px; bottom: 74px; z-index: 2147483647; padding: 12px 14px; border-radius: 12px; background: #111118; color: #ededf2; font-size: 13.5px;
      border: 1px solid #2a2a35; box-shadow: 0 12px 40px rgba(0,0,0,.4); max-width: 340px; }
    .toast a { color: #a9a7ff; font-weight: 650; }
    .err { color: #fda4af; font-size: 12.5px; }
  </style>
  <button class="fab" part="fab" title="Capture elements into an AgentBoard ticket (Alt+Shift+A)"><span class="mark">◎</span>AgentBoard <kbd>⌥⇧A</kbd></button>`
  const fab = root.querySelector(".fab")
  const state = { selecting: false, selected: [], hover: null, screenshot: null, kind: "bug" }
  let hoverBox = null, bar = null, panel = null
  const boxes = new Map()

  function box(el, cls, label) {
    const b = document.createElement("div")
    b.className = "hl " + cls
    const r = el.getBoundingClientRect()
    Object.assign(b.style, { left: `${r.x + scrollX}px`, top: `${r.y + scrollY}px`, width: `${r.width}px`, height: `${r.height}px`, position: "absolute" })
    b.innerHTML = `<span class="lbl"></span>`
    b.querySelector(".lbl").textContent = label
    root.appendChild(b)
    return b
  }
  const labelFor = (el) => { const t = templateFor(el); return t ? t.replace(/^app\/views\//, "") : el.tagName.toLowerCase() }
  const isOurs = (el) => el === host || host.contains(el)

  function onMove(e) {
    const el = document.elementFromPoint(e.clientX, e.clientY)
    if (!el || isOurs(el) || el === state.hover) return
    state.hover = el
    hoverBox?.remove()
    hoverBox = box(el, "", labelFor(el))
  }
  function onClick(e) {
    if (isOurs(e.target)) return
    e.preventDefault(); e.stopPropagation()
    const el = state.hover || e.target
    const existing = state.selected.findIndex(s => s.el === el)
    if (existing >= 0) { boxes.get(el)?.remove(); boxes.delete(el); state.selected.splice(existing, 1) }
    else { if (!e.shiftKey) clearSelection(); state.selected.push(describe(el)); boxes.set(el, box(el, "sel", labelFor(el))) }
    renderBar()
    if (!e.shiftKey && state.selected.length) openPanel()
  }
  const blockEvent = (e) => { if (!isOurs(e.target)) { e.preventDefault(); e.stopPropagation() } }
  function clearSelection() { boxes.forEach(b => b.remove()); boxes.clear(); state.selected = [] }

  function startSelecting() {
    if (state.selecting) return
    state.selecting = true
    document.addEventListener("mousemove", onMove, true)
    document.addEventListener("click", onClick, true)
    ;["mousedown", "mouseup", "submit"].forEach(t => document.addEventListener(t, blockEvent, true))
    document.documentElement.style.cursor = "crosshair"
    bar = document.createElement("div"); bar.className = "bar"; root.appendChild(bar); renderBar()
  }
  function stopSelecting() {
    state.selecting = false
    document.removeEventListener("mousemove", onMove, true)
    document.removeEventListener("click", onClick, true)
    ;["mousedown", "mouseup", "submit"].forEach(t => document.removeEventListener(t, blockEvent, true))
    document.documentElement.style.cursor = ""
    hoverBox?.remove(); hoverBox = null; bar?.remove(); bar = null
  }
  function renderBar() {
    if (!bar) return
    bar.innerHTML = `<span>Click an element · <b>Shift</b>+click to add more · <b>Esc</b> to cancel</span>
      <button class="btn primary" data-next ${state.selected.length ? "" : "disabled"}>Continue (${state.selected.length})</button>`
    bar.querySelector("[data-next]").onclick = () => openPanel()
  }

  function openPanel() {
    stopSelecting()
    panel?.remove()
    panel = document.createElement("div"); panel.className = "panel"
    const route = cfg.route || location.pathname
    panel.innerHTML = `
      <div class="ph">New AgentBoard ticket<button class="x" title="Close">×</button></div>
      <div class="pb">
        <label>Title<input data-title maxlength="200" value=""></label>
        <div class="seg">${["bug", "feature", "task"].map(k => `<button type="button" data-kind="${k}" class="${k === state.kind ? "on" : ""}">${k[0].toUpperCase() + k.slice(1)}</button>`).join("")}</div>
        <label>What's wrong or what should change?<textarea data-desc placeholder="Describe the problem or the change you want…"></textarea></label>
        <label>Expected result <span style="font-weight:400;color:#6e6e7c">(becomes an acceptance criterion)</span><input data-expected placeholder="e.g. The total shows 2 decimals"></label>
        <label>Priority<select data-priority><option value="0">Urgent</option><option value="1">High</option><option value="2" selected>Medium</option><option value="3">Low</option></select></label>
        <div><div class="meta" style="margin-bottom:8px">Selected elements</div><div class="chips" data-chips></div>
          <button class="btn" type="button" data-more style="margin-top:8px">+ Select more</button></div>
        <label class="check"><input type="checkbox" data-console ${consoleErrors.length ? "checked" : ""}> Include console errors (${consoleErrors.length})</label>
        <div data-shot-area>${cfg.screenshots ? `<button class="btn" type="button" data-shot>Attach screenshot of the selection</button>` :
          `<div class="meta">Screenshots of the selection <span class="pro">PRO</span></div>`}</div>
        <div class="meta">Page <code>${location.pathname}</code> · route <code>${route}</code><br>${(cfg.templates || []).length} templates rendered on this page</div>
        <div class="err" data-error></div>
      </div>
      <div class="pf"><button class="btn" data-cancel>Cancel</button><button class="btn primary" data-submit>Create ticket</button></div>`
    root.appendChild(panel)
    const first = state.selected[0]
    panel.querySelector("[data-title]").value = first ? `${state.kind === "bug" ? "Fix" : "Change"} ${first.text ? `“${first.text.slice(0, 50)}”` : first.selector.split(" > ").pop()} on ${route}` : `Issue on ${route}`
    renderChips()
    panel.querySelectorAll("[data-kind]").forEach(b => b.onclick = () => { state.kind = b.dataset.kind; panel.querySelectorAll("[data-kind]").forEach(x => x.classList.toggle("on", x === b)) })
    panel.querySelector(".x").onclick = panel.querySelector("[data-cancel]").onclick = close
    panel.querySelector("[data-more]").onclick = () => { panel.remove(); panel = null; startSelecting() }
    panel.querySelector("[data-submit]").onclick = submit
    panel.querySelector("[data-shot]")?.addEventListener("click", takeScreenshot)
    setTimeout(() => panel.querySelector("[data-desc]").focus(), 50)
  }
  function renderChips() {
    const list = panel.querySelector("[data-chips]")
    list.innerHTML = ""
    state.selected.forEach((s, i) => {
      const c = document.createElement("div"); c.className = "chip"
      c.innerHTML = `<code></code><button class="rm" title="Remove">×</button><span class="tpl"></span>`
      c.querySelector("code").textContent = s.selector
      c.querySelector(".tpl").textContent = s.template ? `↳ ${s.template}` : "↳ template unknown (enable annotate_rendered_view_with_filenames)"
      c.querySelector(".rm").onclick = () => { boxes.get(s.el)?.remove(); boxes.delete(s.el); state.selected.splice(i, 1); renderChips() }
      list.appendChild(c)
    })
  }

  // Pro: capture the current tab once (the browser asks for permission) and crop to the
  // union of the selected elements.
  async function takeScreenshot() {
    const area = panel.querySelector("[data-shot-area]")
    try {
      panel.style.visibility = "hidden"; boxes.forEach(b => b.style.visibility = "hidden")
      const stream = await navigator.mediaDevices.getDisplayMedia({ video: { displaySurface: "browser" }, preferCurrentTab: true, audio: false })
      const video = document.createElement("video"); video.srcObject = stream; await video.play()
      await new Promise(r => setTimeout(r, 250))
      const scale = video.videoWidth / innerWidth
      const rects = state.selected.map(s => s.el.getBoundingClientRect())
      const pad = 16
      const x = Math.max(0, Math.min(...rects.map(r => r.left)) - pad), y = Math.max(0, Math.min(...rects.map(r => r.top)) - pad)
      const w = Math.min(innerWidth, Math.max(...rects.map(r => r.right)) + pad) - x, h = Math.min(innerHeight, Math.max(...rects.map(r => r.bottom)) + pad) - y
      const canvas = document.createElement("canvas"); canvas.width = w * scale; canvas.height = h * scale
      canvas.getContext("2d").drawImage(video, x * scale, y * scale, w * scale, h * scale, 0, 0, canvas.width, canvas.height)
      stream.getTracks().forEach(t => t.stop())
      state.screenshot = canvas.toDataURL("image/png")
      area.innerHTML = `<img class="shot" alt="Screenshot of the selection"><button class="btn" type="button" data-unshot style="margin-top:8px">Remove screenshot</button>`
      area.querySelector("img").src = state.screenshot
      area.querySelector("[data-unshot]").onclick = () => { state.screenshot = null; openPanel() }
    } catch (err) {
      area.insertAdjacentHTML("beforeend", `<div class="err">Screenshot cancelled or not supported in this browser.</div>`)
    } finally {
      if (panel) panel.style.visibility = ""; boxes.forEach(b => b.style.visibility = "")
    }
  }

  async function submit() {
    const btn = panel.querySelector("[data-submit]"); btn.disabled = true; btn.textContent = "Creating…"
    const payload = { capture: {
      title: panel.querySelector("[data-title]").value, description: panel.querySelector("[data-desc]").value,
      expected: panel.querySelector("[data-expected]").value, kind: state.kind, priority: panel.querySelector("[data-priority]").value,
      url: location.href, route: cfg.route, viewport: { width: innerWidth, height: innerHeight }, user_agent: navigator.userAgent,
      templates: cfg.templates || [], console_errors: panel.querySelector("[data-console]").checked ? consoleErrors : [],
      elements: state.selected.map(({ el, ...rest }) => rest), screenshot: state.screenshot || undefined
    } }
    try {
      const res = await fetch(cfg.endpoint, { method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
        body: JSON.stringify(payload) })
      const data = await res.json().catch(() => ({}))
      if (!res.ok || !data.ok) throw new Error(data?.error?.message || `HTTP ${res.status}`)
      close()
      const t = document.createElement("div"); t.className = "toast"
      t.innerHTML = `✓ Created <a target="_blank" rel="noopener"></a> in AgentBoard`
      t.querySelector("a").textContent = data.key; t.querySelector("a").href = data.url
      root.appendChild(t); setTimeout(() => t.remove(), 7000)
    } catch (err) {
      panel.querySelector("[data-error]").textContent = `Could not create the ticket: ${err.message}`
      btn.disabled = false; btn.textContent = "Create ticket"
    }
  }

  function close() { panel?.remove(); panel = null; stopSelecting(); clearSelection(); state.screenshot = null }

  fab.addEventListener("click", () => state.selecting ? stopSelecting() : startSelecting())
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && (state.selecting || panel)) { e.preventDefault(); close() }
    if (e.altKey && e.shiftKey && (e.key === "A" || e.key === "a" || e.code === "KeyA")) { e.preventDefault(); state.selecting ? stopSelecting() : startSelecting() }
  }, true)
})()
