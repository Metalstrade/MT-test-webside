-- ============================================================
-- METALS TRADING — LISTING CERTIFICATES MIGRATION
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
-- ============================================================

-- 1. Novi stolpci v tabeli listings
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_quality  boolean DEFAULT false;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_weight   boolean DEFAULT false;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_analysis boolean DEFAULT false;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_files    jsonb;

-- 2. Storage bucket za certifikate prodajalcev
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'listing-certs',
  'listing-certs',
  false,
  20971520,  -- 20 MB
  ARRAY['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO NOTHING;

-- 3. Storage policies
DROP POLICY IF EXISTS "owner_upload_listing_cert" ON storage.objects;
DROP POLICY IF EXISTS "auth_read_listing_cert"    ON storage.objects;
DROP POLICY IF EXISTS "owner_delete_listing_cert" ON storage.objects;

-- Prijavljen uporabnik lahko naloži certifikat
CREATE POLICY "owner_upload_listing_cert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'listing-certs'
    AND auth.uid() IS NOT NULL
  );

-- Prijavljen uporabnik (prodajalec ali admin) lahko bere
CREATE POLICY "auth_read_listing_cert" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'listing-certs'
    AND auth.uid() IS NOT NULL
  );

-- Prijavljen uporabnik lahko briše
CREATE POLICY "owner_delete_listing_cert" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'listing-certs'
    AND auth.uid() IS NOT NULL
  );
