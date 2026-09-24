-- ============================================================
-- METALS TRADING — POPRAVEK: manjkajoč stolpec cert_assay
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
--
-- NAPAKA OB OBJAVI OGLASA: "Could not find the 'cert_assay' column
-- of 'listings' in the schema cache"
--
-- VZROK: obrazec za objavo oglasa (4. korak — certifikati) pošilja
-- vseh 7 cert_* stolpcev (auth, serial, mint, assay, quality, weight,
-- analysis), a supabase-migration-listing-certs.sql je pri dodajanju
-- stolpcev pomotoma izpustil "cert_assay".
--
-- Vsi ALTER TABLE spodaj so IF NOT EXISTS — varno za pognati tudi če
-- so nekateri stolpci že prisotni.
-- ============================================================

ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_auth     boolean DEFAULT false;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_serial   boolean DEFAULT false;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_mint     boolean DEFAULT false;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_assay    boolean DEFAULT false;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_quality  boolean DEFAULT false;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_weight   boolean DEFAULT false;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_analysis boolean DEFAULT false;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS cert_files    jsonb;

-- Prisili takojšnjo osvežitev PostgREST shema-predpomnilnika, da ni
-- treba čakati na naslednjo samodejno osvežitev.
NOTIFY pgrst, 'reload schema';
