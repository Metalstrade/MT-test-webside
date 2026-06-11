-- ============================================================
-- METALS TRADING — ORDER DOCUMENTS MIGRATION
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
-- ============================================================

-- 1. Tabela za dokumente naročil
CREATE TABLE IF NOT EXISTS order_documents (
  id              uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  transaction_id  uuid,
  buyer_id        uuid NOT NULL,
  document_type   text NOT NULL,
  document_category text NOT NULL,
  file_name       text NOT NULL,
  file_path       text NOT NULL,
  file_size       integer DEFAULT 0,
  uploaded_at     timestamptz DEFAULT now(),
  uploaded_by     uuid
);

-- 2. Row Level Security
ALTER TABLE order_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "buyers_view_own" ON order_documents;
DROP POLICY IF EXISTS "authenticated_insert" ON order_documents;
DROP POLICY IF EXISTS "authenticated_delete" ON order_documents;

-- Kupci vidijo samo svoje dokumente
CREATE POLICY "buyers_view_own" ON order_documents
  FOR SELECT USING (buyer_id = auth.uid());

-- Prijavljeni uporabniki (admin) lahko nalagajo dokumente
CREATE POLICY "authenticated_insert" ON order_documents
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- Prijavljeni uporabniki (admin) lahko brišejo dokumente
CREATE POLICY "authenticated_delete" ON order_documents
  FOR DELETE USING (auth.uid() IS NOT NULL);

-- 3. Storage bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'order-documents',
  'order-documents',
  false,
  52428800,  -- 50 MB
  ARRAY['application/pdf', 'image/jpeg', 'image/png']
)
ON CONFLICT (id) DO NOTHING;

-- 4. Storage policies
DROP POLICY IF EXISTS "buyers_download_own_docs" ON storage.objects;
DROP POLICY IF EXISTS "auth_upload_docs" ON storage.objects;
DROP POLICY IF EXISTS "auth_delete_docs" ON storage.objects;

-- Kupci lahko prenesejo svoje datoteke
CREATE POLICY "buyers_download_own_docs" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'order-documents'
    AND EXISTS (
      SELECT 1 FROM order_documents
      WHERE file_path = name AND buyer_id = auth.uid()
    )
  );

-- Prijavljeni lahko nalagajo
CREATE POLICY "auth_upload_docs" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'order-documents'
    AND auth.uid() IS NOT NULL
  );

-- Prijavljeni lahko brišejo
CREATE POLICY "auth_delete_docs" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'order-documents'
    AND auth.uid() IS NOT NULL
  );
