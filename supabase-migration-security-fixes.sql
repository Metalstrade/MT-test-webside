-- ============================================================
-- METALS TRADING — SECURITY FIXES MIGRATION
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
-- ============================================================

-- ══ 1. ADMIN RPC — dodaj email preverjanje ══

CREATE OR REPLACE FUNCTION admin_get_transactions()
RETURNS SETOF transactions
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_email text;
BEGIN
  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();
  IF lower(v_email) NOT IN ('metals-trade@protonmail.com', 'jani.zibert@gazela.si') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  RETURN QUERY SELECT * FROM transactions ORDER BY created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION admin_get_verifications()
RETURNS TABLE (
  id uuid, user_id uuid, user_email text, file_path text,
  file_name text, status text, created_at timestamptz, reviewed_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_email text;
BEGIN
  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();
  IF lower(v_email) NOT IN ('metals-trade@protonmail.com', 'jani.zibert@gazela.si') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  RETURN QUERY
    SELECT v.id, v.user_id, v.user_email, v.file_path, v.file_name,
           v.status, v.created_at, v.reviewed_at
    FROM verifications v ORDER BY v.created_at DESC;
END;
$$;

-- ══ 2. order_documents — samo admin vstavi/briše ══

DROP POLICY IF EXISTS "authenticated_insert" ON order_documents;
DROP POLICY IF EXISTS "authenticated_delete" ON order_documents;

CREATE POLICY "admin_insert_docs" ON order_documents
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM auth.users WHERE id = auth.uid()
            AND email IN ('metals-trade@protonmail.com','jani.zibert@gazela.si'))
  );

CREATE POLICY "admin_delete_docs" ON order_documents
  FOR DELETE USING (
    EXISTS (SELECT 1 FROM auth.users WHERE id = auth.uid()
            AND email IN ('metals-trade@protonmail.com','jani.zibert@gazela.si'))
  );

-- ══ 3. order-documents storage — samo admin naloži/briše ══
-- Opomba: storage politike ne morejo brati auth.users — uporabi auth.email()

DROP POLICY IF EXISTS "auth_upload_docs"  ON storage.objects;
DROP POLICY IF EXISTS "auth_delete_docs"  ON storage.objects;
DROP POLICY IF EXISTS "admin_upload_docs" ON storage.objects;
DROP POLICY IF EXISTS "admin_delete_docs" ON storage.objects;

CREATE POLICY "admin_upload_docs" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'order-documents'
    AND auth.email() IN ('metals-trade@protonmail.com', 'jani.zibert@gazela.si')
  );

CREATE POLICY "admin_delete_docs" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'order-documents'
    AND auth.email() IN ('metals-trade@protonmail.com', 'jani.zibert@gazela.si')
  );

-- ══ 4. listing-certs — samo lastnik oglasa ali admin bere ══

DROP POLICY IF EXISTS "auth_read_listing_cert"          ON storage.objects;
DROP POLICY IF EXISTS "owner_or_admin_read_listing_cert" ON storage.objects;

CREATE POLICY "owner_or_admin_read_listing_cert" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'listing-certs'
    AND (
      auth.uid()::text = split_part(name, '/', 1)
      OR auth.email() IN ('metals-trade@protonmail.com', 'jani.zibert@gazela.si')
    )
  );
