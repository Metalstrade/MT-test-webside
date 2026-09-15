-- ============================================================
-- METALS TRADING — DOSTOP PREKO VERIFIKACIJE (ne registracije)
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
--
-- SPREMEMBA POSLOVNE LOGIKE:
--   PREJ:  registracija → admin odobri registracijo → dostop do trga
--   ZDAJ:  registracija → takoj dostopna (brskanje) →
--          uporabnik odda verifikacijo (dokument) v Nastavitvah →
--          admin odobri VERIFIKACIJO → šele TO odklene oddajo
--          oglasov in nakup (marketplace_approved = true)
--
-- admin_review_registration ostane (admin lahko še vedno pregleduje
-- seznam prijav), a NE odklepa/zaklepa več dostopa do trga — samo
-- beleži status v user_registrations, za pregled/evidenco.
-- ============================================================

-- ══ 1. admin_review_verification — ZDAJ odklepa dostop do trga ══

CREATE OR REPLACE FUNCTION public.admin_review_verification(p_id uuid, p_approve boolean)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_email   text;
  v_user_id uuid;
  v_status  text;
BEGIN
  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();
  IF v_email IS NULL OR lower(v_email) NOT IN ('metals-trade@protonmail.com', 'jani.zibert@gazela.si') THEN
    RETURN json_build_object('error', 'Unauthorized');
  END IF;

  v_status := CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;

  SELECT user_id INTO v_user_id FROM public.verifications WHERE id = p_id;
  IF v_user_id IS NULL THEN
    RETURN json_build_object('error', 'not_found');
  END IF;

  UPDATE public.verifications
     SET status = v_status, reviewed_at = now()
   WHERE id = p_id;

  -- Odobrena verifikacija = dostop do trga (oddaja oglasov + nakup).
  -- Zavrnitev dostop odvzame (na primer, če je bila prej pomotoma odobrena).
  UPDATE auth.users
     SET raw_user_meta_data = raw_user_meta_data
       || jsonb_build_object('marketplace_approved', p_approve, 'verified', p_approve)
   WHERE id = v_user_id;

  RETURN json_build_object('ok', true);
END; $$;

REVOKE EXECUTE ON FUNCTION public.admin_review_verification(uuid, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_review_verification(uuid, boolean) TO authenticated;

-- ══ 2. admin_review_registration — samo evidenca, NE odklepa dostopa ══

CREATE OR REPLACE FUNCTION public.admin_review_registration(p_id uuid, p_approve boolean)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_email  text;
  v_status text;
BEGIN
  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();
  IF v_email IS NULL OR lower(v_email) NOT IN ('metals-trade@protonmail.com', 'jani.zibert@gazela.si') THEN
    RETURN json_build_object('error', 'Unauthorized');
  END IF;

  v_status := CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;

  UPDATE public.user_registrations
     SET status = v_status, updated_at = now()
   WHERE id = p_id;

  -- Namerno NE spreminja marketplace_approved — dostop do trga odslej
  -- ureja izključno admin_review_verification.
  RETURN json_build_object('ok', true);
END; $$;

REVOKE EXECUTE ON FUNCTION public.admin_review_registration(uuid, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_review_registration(uuid, boolean) TO authenticated;
