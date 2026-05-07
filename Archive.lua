-- Tally — Archive.lua
--
-- Per-month (and optionally per-week) archive storage for sealed ledger
-- entries. See TLY-51 for the locked design spec.
--
-- Storage layout (TallyDB.ledger):
--   active       = <serialised+deflated blob>          -- mutable, hot path
--   activeMeta   = { count, savedAt, ... }
--   archives     = {
--     ["2025-10"]    = { blob, count, fromTs, toTs, bytes, schemaVer },
--     ["2025-12-w1"] = { ... },                         -- subdivided when month >50k rows
--     ...
--   }
--   archiveIndex = {
--     ["2025-10"] = { itemIDs, charKeys, kindCounts, monthlyAggregates },
--     ...
--   }
--
-- Archives are write-once at seal time, read-only thereafter (until a
-- schema-version bump triggers full rebuild). archiveIndex stays resident
-- in memory; archive blobs deserialise on demand and cache LRU(3).
--
-- This file is the storage primitive only. Sealing policy (when to cut
-- entries from active → archives) lives in Ledger.lua. Lazy-load + LRU
-- eviction lives here.
--
-- Phase 1 (alpha16): module skeleton lands on feat/tly-51-tiered-storage.
-- Wiring into Ledger:Query/Reconcile follows in subsequent commits.

local addonName, ns = ...

local Archive = {}
ns.Archive = Archive
