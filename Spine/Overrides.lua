-- Tally — Spine/Overrides.lua
--
-- Sparse manual dedup/merge overrides for the projection-layer redesign
-- (TLY-80).
--
-- The data spine never stores a ledger — the unified ledger is recomputed
-- from sibling sources on every parse (see Spine/Dedup.lua). The *one*
-- thing the spine must persist is the set of manual corrections a player
-- has made: "TSM and FlipQueue disagreed on this sale's price and I say
-- it was 99g", "these two rows are not the same event, keep them apart".
--
-- This is safe to persist because it is bounded by *human attention*, not
-- by trade volume — a player resolves a handful of conflicts, not a row
-- per transaction. Nothing here grows with the ledger, so it does not
-- reintroduce the Lua constant-pool wall the redesign exists to remove.
--
-- Storage:
--   TallyDB.merge = {
--     version   = 1,
--     overrides = {
--       ["<Dedup.entryKey>"] = {
--         kind       = "field" | "ignore" | "merge" | "split",
--         field      = "copper",     -- for kind == "field"
--         value      = 990000,       -- for kind == "field"
--         resolvedAt = <epoch>,
--         note       = "<free text>",
--       }, ...
--     },
--   }
--
-- Override keys are Dedup.entryKey() values — derived from the sorted
-- original source-row ids — so an override survives a relog as long as
-- the underlying source rows still exist.

local addonName, ns = ...

ns.Spine = ns.Spine or {}

local Overrides = {}
ns.Spine.Overrides = Overrides

local SCHEMA_VERSION = 1

-- Accepted override kinds.
--   field  — replace one merged field with an authoritative value and
--            clear the conflict it resolves.
--   ignore — drop the unified record entirely (a false-positive merge, or
--            a row the player does not want counted).
--   merge  — force two records together. Escape hatch for when the
--            content key splits one real event; data shape is accepted
--            now, the resolving engine lands with its UI later.
--   split  — force a merged record apart. The mirror escape hatch.
local OVERRIDE_KINDS = {
  field  = true,
  ignore = true,
  merge  = true,
  split  = true,
}

-- Ensure TallyDB.merge exists and is at the current schema version, then
-- return the overrides map. Tester data is expendable during alpha
-- (TallyCharDB.tally_schema_version gates the clean break), so a
-- version mismatch simply resets rather than migrating.
local function store()
  TallyDB = TallyDB or {}
  local m = TallyDB.merge
  if type(m) ~= "table" or m.version ~= SCHEMA_VERSION then
    m = { version = SCHEMA_VERSION, overrides = {} }
    TallyDB.merge = m
  end
  m.overrides = m.overrides or {}
  return m.overrides
end

-- ── CRUD ────────────────────────────────────────────────────────────────

-- The override for a unified-record key, or nil.
function Overrides:Get(key)
  if type(key) ~= "string" then return nil end
  return store()[key]
end

-- Record an override. Validates kind; a "field" override requires both a
-- field name and a value. Stamps resolvedAt if the caller did not.
-- Returns the stored override, or nil + reason on a validation failure.
function Overrides:Set(key, override)
  if type(key) ~= "string" or key == "" then
    return nil, "invalid key"
  end
  if type(override) ~= "table" or not OVERRIDE_KINDS[override.kind] then
    return nil, "invalid override kind"
  end
  if override.kind == "field" then
    if type(override.field) ~= "string" or override.field == "" then
      return nil, "field override requires a field name"
    end
    if override.value == nil then
      return nil, "field override requires a value"
    end
  end
  local entry = {
    kind       = override.kind,
    field      = override.field,
    value      = override.value,
    note       = override.note,
    resolvedAt = override.resolvedAt or time(),
  }
  store()[key] = entry
  return entry
end

-- Remove an override. Returns true if one was present.
function Overrides:Remove(key)
  if type(key) ~= "string" then return false end
  local overrides = store()
  if overrides[key] == nil then return false end
  overrides[key] = nil
  return true
end

-- The full overrides map (live reference — callers must not mutate it
-- except through Set/Remove).
function Overrides:All()
  return store()
end

-- Number of overrides currently stored. For /tally diag.
function Overrides:Count()
  local n = 0
  for _ in pairs(store()) do n = n + 1 end
  return n
end

-- ── Application ─────────────────────────────────────────────────────────

-- Apply any stored override to a unified record produced by Dedup.merge.
--
-- Returns the (possibly mutated) record, or nil when an "ignore" override
-- drops it. Records with no override pass through untouched.
--
--   field  — replaces record[field]; if the field had a logged conflict,
--            the conflict is cleared and the record's review flag is
--            recomputed from any remaining conflicts.
--   ignore — returns nil so the caller omits the record.
--   merge / split — accepted and stamped onto the record as
--            record.pendingOverride for a future resolving engine; the
--            record itself is passed through unchanged for now.
--
-- The record is mutated in place (it is a fresh table from Dedup.merge
-- each recompute, so this is safe and avoids a copy).
function Overrides:Apply(record)
  if type(record) ~= "table" then return record end
  local ov = self:Get(record.id)
  if not ov then return record end

  if ov.kind == "ignore" then
    return nil
  end

  if ov.kind == "field" then
    record[ov.field] = ov.value
    record.overridden = true
    record.provenance = record.provenance or {}
    record.provenance[ov.field] = "override"
    if record.conflicts and record.conflicts[ov.field] then
      record.conflicts[ov.field] = nil
      if next(record.conflicts) == nil then
        record.conflicts = nil
        record.review = nil
      end
    end
    return record
  end

  -- merge / split: not yet resolved here. Annotate and pass through so
  -- the record stays visible and the future engine can pick it up.
  record.pendingOverride = ov.kind
  return record
end
