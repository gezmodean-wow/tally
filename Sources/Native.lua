-- Tally — Sources/Native.lua
--
-- Orchestrator for Tally's own native event-capture pipeline. Each transaction
-- bucket (AH invoices, AH posting, vendor activity, repair, personal mail)
-- lives in its own `Sources/Native/<Bucket>.lua` file and registers itself
-- via `Native:RegisterBucket(spec)` at file-load time. This file owns:
--
--   * The `tally-native` ledger source registration with Ledger
--   * A shared skip-counter table keyed by bucket prefix (TLY-29)
--   * Shared helpers (`Native.CurrentCharKey`, `Native.SafeNum`)
--   * The `importAll` dispatcher that fans out to every bucket's optional
--     `scan()` function (used by Ledger:ImportFromAllSources)
--
-- The capture path itself is event-driven inside each bucket — buckets hook
-- WoW APIs and write entries via `ns.Ledger:Insert(entry)` as activity
-- happens. `scan()` exists for buckets that can re-derive state from open UI
-- (e.g. AHInvoice's open-mailbox sweep) so the manual "Import now" button
-- and login backfill keep working.
--
-- TLY-31 Phase A: Tally as source of truth, sibling adapters demoting to
-- backfill-only once Native parity is proven.

local addonName, ns = ...

local Native = {}
ns.Sources = ns.Sources or {}
ns.Sources.Native = Native

-- Stable identifier for ledger entries originating from native capture.
-- Buckets use it as a prefix when constructing entry IDs.
Native.SOURCE_NAME = "tally-native"

-- Shared skip-counter table. Each bucket pre-creates its own counter slots
-- (with a bucket-prefixed name like "posting_no_link") at file-load time so
-- /tally diag's SkipCounters inspector sees stable keys regardless of
-- whether activity has fired yet. Reset to zero on each :Register() so the
-- values reflect the current session.
Native.skipCounters = {}

-- ============================================================================
-- Shared helpers
-- ============================================================================

function Native.CurrentCharKey()
  local Cogworks = LibStub and LibStub("Cogworks-1.0", true)
  if Cogworks and Cogworks.GetCharacterKey then
    local ok, key = pcall(Cogworks.GetCharacterKey, Cogworks)
    if ok and key then return key end
  end
  local name = UnitName and UnitName("player") or ""
  local realm = GetRealmName and GetRealmName() or ""
  return name .. "-" .. realm
end

function Native.SafeNum(n) return tonumber(n) or 0 end

-- Setup-gate predicate. Buckets call this before writing any ledger entry
-- so a player who installs Tally and immediately opens the AH / mail / a
-- vendor doesn't get rows written before the first-run wizard finishes.
function Native.IsCaptureLive()
  if not (ns.Ledger and ns.Ledger.IsSetupComplete) then return true end
  return ns.Ledger:IsSetupComplete()
end

-- ============================================================================
-- Bucket registration
-- ============================================================================

Native._buckets = {}

-- spec = { name = string, scan = function() -> insertedN, skippedN }
-- `scan` is optional; pure event-driven buckets (e.g. AHPosting) leave it
-- unset because there's nothing to re-derive from open UI.
function Native:RegisterBucket(spec)
  assert(type(spec) == "table" and type(spec.name) == "string",
    "Native:RegisterBucket — spec.name required")
  self._buckets[#self._buckets + 1] = spec
end

-- ============================================================================
-- Source registration with Ledger
-- ============================================================================

-- Generic ImportFromAllSources path: fan out to every bucket's optional
-- `scan` function, summing inserted/skipped. Event-driven buckets contribute
-- 0/0 (their entries arrive in real time, not on demand).
local function importAll()
  local inserted, skipped = 0, 0
  for _, bucket in ipairs(Native._buckets) do
    if type(bucket.scan) == "function" then
      local ok, i, s = pcall(bucket.scan)
      if ok then
        inserted = inserted + (i or 0)
        skipped  = skipped  + (s or 0)
      end
    end
  end
  return inserted, skipped
end

function Native:Register()
  if not ns.Ledger or not ns.Ledger.RegisterSource then return end
  for k in pairs(self.skipCounters) do self.skipCounters[k] = 0 end
  ns.Ledger:RegisterSource(self.SOURCE_NAME, {
    label = "Tally (native events)",
    importFn = importAll,
    isAvailable = function() return true end,
  })
end
