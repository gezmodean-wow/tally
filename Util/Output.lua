-- Tally — Util/Output.lua
--
-- Centralised output-channel routing per TLY-70. Channel taxonomy:
--
--   Status (brief player-facing, transient)    → cw:Toast
--   Errors (player-facing, severity-coloured)  → cw:Toast severity="error"
--   Inspectable detail (multi-line, paste)     → cw:CreateCopyDialog
--   Engineering / debug traces                 → ns.dbg:PrintDebug (logged + console)
--   Chat                                       → degraded fallback only / explicit opt-in
--
-- Every Tally module emits user-visible output through this router instead
-- of calling `print(...)` directly. Chat is the wrong substrate for both
-- quick acknowledgements (toasts are transient, off-screen, severity-tinted)
-- and inspectable detail (copy dialog gives paste-ready text). Engineering
-- traces are noise to the player and belong in the debug log.

local addonName, ns = ...

local Output = {}
ns.Output = Output

local function cw()
  return LibStub and LibStub("Cogworks-1.0", true) or nil
end

-- ============================================================================
-- Status (toast)
-- ============================================================================
--
-- severity:
--   "success" — green; routine OK confirmations
--   "info"    — blue; informational status (default)
--   "warning" — orange; non-blocking concerns
--   "error"   — red; failures the player needs to see
--
-- opts (optional table):
--   duration  number  — seconds before auto-dismiss (Cogworks default 3s)
--   icon      string  — texture path; otherwise severity-tinted indicator
--   onClick   function — fired on toast click
--
-- Every status message is mirrored to the debug log so trace inspection
-- can correlate UI events with internal state.

function Output:Status(text, severity, opts)
  severity = severity or "info"
  local lib = cw()
  if lib and lib.Toast then
    lib:Toast({
      text     = text,
      severity = severity,
      duration = opts and opts.duration,
      icon     = opts and opts.icon,
      onClick  = opts and opts.onClick,
    })
  elseif lib and severity == "error" and lib.PrintError then
    lib:PrintError(addonName, text)
  elseif lib and lib.Print then
    lib:Print(addonName, text)
  else
    print("Tally: " .. tostring(text))
  end
  if ns.dbg and ns.dbg.PrintDebug then
    ns.dbg:PrintDebug("status/" .. severity .. ": " .. tostring(text))
  end
end

function Output:Success(text, opts) return self:Status(text, "success", opts) end
function Output:Info(text, opts)    return self:Status(text, "info",    opts) end
function Output:Warn(text, opts)    return self:Status(text, "warning", opts) end
function Output:Error(text, opts)   return self:Status(text, "error",   opts) end

-- ============================================================================
-- Inspect (copy dialog)
-- ============================================================================
--
-- Multi-line tabular output, diagnostic dumps, anything a tester might
-- paste into a GitHub issue. Convention for /tally diag *.

function Output:Inspect(text, hint)
  local lib = cw()
  if lib and lib.CreateCopyDialog then
    lib:CreateCopyDialog(text, hint)
    return
  end
  self:Warn("Copy dialog unavailable; printing to chat as fallback.")
  for line in tostring(text):gmatch("[^\n]+") do print(line) end
end

-- ============================================================================
-- Debug (logger + console)
-- ============================================================================
--
-- Engineering traces. Goes to the Cogworks ring buffer; visible in the
-- /tally debug console. Chat echo is gated by the addon's debug flag
-- (TallyDB.debug).

function Output:Debug(...)
  if ns.dbg and ns.dbg.PrintDebug then
    ns.dbg:PrintDebug(...)
  end
end

-- ============================================================================
-- Chat (explicit opt-in only)
-- ============================================================================
--
-- Degraded fallback for `/tally <cmd> chat`-style subcommands where the
-- user explicitly asked for inline output. Do not call from non-opt-in
-- paths — the channel taxonomy exists precisely so default code doesn't
-- spray chat output.

function Output:Chat(text)
  local lib = cw()
  if lib and lib.Print then
    lib:Print(addonName, text)
  else
    print("Tally: " .. tostring(text))
  end
end
