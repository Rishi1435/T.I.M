-- ============================================================
-- T.I.M. (This Is Me) — Supabase schema migration 0001
-- ============================================================
-- Master Blueprint v0.2 — Supabase is used for TWO things only:
--   1. Multi-tenant auth (owner / wife / sister / friends).
--   2. Encrypted memory blob sync — `memory_blobs` stores ONLY
--      ciphertext produced by the Flutter app's CryptoService.
--
-- No pgvector. No readable metadata. Supabase is a dumb ciphertext
-- bucket. Recovery requires the user's master password.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ------------------------------------------------------------
-- Table: memory_blobs (one row per user, latest wins)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.memory_blobs (
  user_id     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  blob        BYTEA NOT NULL,                -- AES-256-GCM ciphertext
  version     INTEGER NOT NULL DEFAULT 1,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.memory_blobs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_read_own_blob"
  ON public.memory_blobs FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "users_upsert_own_blob"
  ON public.memory_blobs FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "users_update_own_blob"
  ON public.memory_blobs FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS on_memory_blob_touch ON public.memory_blobs;
CREATE TRIGGER on_memory_blob_touch
  BEFORE UPDATE ON public.memory_blobs
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
