-- ============================================================
-- 0002 — right-to-erasure: users may delete their own ciphertext.
-- Without this, "wipe my cloud backup" silently fails under RLS.
-- ============================================================
CREATE POLICY "users_delete_own_blob"
  ON public.memory_blobs FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);
