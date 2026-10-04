-- ============================================================
-- METALS TRADING — STROŠEK PREVOZA NA RAČUNU
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
--
-- Cena na kartici oglasa ne vključuje prevoza. Admin lahko za
-- posamezno naročilo (transakcijo) pred izdajo računa doda strošek
-- prevoza — ta se prišteje k osnovnemu znesku in tvori končni
-- znesek za plačilo (email s plačilnimi navodili + generirani
-- dokumenti v doc-templates.html uporabljajo že to vsoto, saj
-- admin.html pošlje amount = transactions.amount + transport_cost).
-- ============================================================

ALTER TABLE transactions ADD COLUMN IF NOT EXISTS transport_cost numeric DEFAULT 0;

CREATE OR REPLACE FUNCTION public.admin_set_transport_cost(p_id uuid, p_transport_cost numeric)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_email text;
BEGIN
  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();
  IF v_email IS NULL OR lower(v_email) NOT IN ('metals-trade@protonmail.com', 'jani.zibert@gazela.si') THEN
    RETURN json_build_object('error', 'Unauthorized');
  END IF;
  IF p_transport_cost IS NULL OR p_transport_cost < 0 THEN
    RETURN json_build_object('error', 'invalid_amount');
  END IF;

  UPDATE public.transactions SET transport_cost = p_transport_cost WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN json_build_object('error', 'not_found');
  END IF;

  RETURN json_build_object('ok', true);
END; $$;

REVOKE EXECUTE ON FUNCTION public.admin_set_transport_cost(uuid, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_set_transport_cost(uuid, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
