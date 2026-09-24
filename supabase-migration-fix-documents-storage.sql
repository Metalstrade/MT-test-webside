-- ============================================================
-- METALS TRADING — POPRAVEK: admin ne more odpreti verifikacijskih PDF-jev
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
--
-- VZROK: bucket "documents" (kamor uporabniki nalagajo dokumente za
-- verifikacijo računa) nima storage politike, ki bi adminu dovolila
-- SELECT (createSignedUrl) na tuje datoteke. Tabela `verifications`
-- ima že admin RPC (admin_get_verifications), a sam storage bucket
-- ostaja zaklenjen. Enak bug je bil že odpravljen za bucketa
-- "listing-certs" in "order-documents" (supabase-migration-security-fixes.sql),
-- le za "documents" je bil spregledan.
-- ============================================================

DROP POLICY IF EXISTS "owner_or_admin_read_documents" ON storage.objects;

CREATE POLICY "owner_or_admin_read_documents" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'documents'
    AND (
      -- lastnik: pot je oblike verifications/{user_id}/{datoteka}
      auth.uid()::text = split_part(name, '/', 2)
      OR auth.email() IN ('metals-trade@protonmail.com', 'jani.zibert@gazela.si')
    )
  );
