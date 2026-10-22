-- ============================================================
-- METALS TRADING — OBVESTI ADMINA OB NOVEM NAROČILU
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
--
-- VZROK PRIJAVLJENE NAPAKE: ko kupec pritisne "Kupi zdaj" (ali zmaga
-- dražbo), sprožilec on_transaction_insert() (iz
-- supabase-migration-messaging.sql) ustvari in-app obvestilo za
-- PRODAJALCA in KUPCA — admina pa nikoli ni obveščal. Ker je tabela
-- `notifications` že povezana na e-poštni webhook (edge funkcija
-- notify-email), bo admin zdaj za vsako novo naročilo prejel tudi
-- e-pošto, enako kot že prejmeta kupec in prodajalec.
--
-- Opomba: e-pošta se dejansko pošlje le, če je v Supabase nastavljen
-- Database Webhook na INSERT v notifications → notify-email, in če so
-- v tej edge funkciji nastavljene skrivnosti RESEND_API_KEY /
-- NOTIFY_FROM. Če to obvestilo že deluje za prodajalca/kupca, bo
-- delovalo tudi za admina brez dodatnih nastavitev.
-- ============================================================

CREATE OR REPLACE FUNCTION public.on_transaction_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_admin_id uuid;
BEGIN
  INSERT INTO public.notifications (user_id, type, title, body, link)
  VALUES (NEW.seller_id, 'sale',
          'Prodano — ' || COALESCE(NEW.listing_title, 'oglas'),
          'Kupec je oddal naročilo (' || NEW.currency || ' ' || NEW.amount || ').',
          'markets.html');

  INSERT INTO public.notifications (user_id, type, title, body, link)
  VALUES (NEW.buyer_id, 'purchase',
          'Naročilo ustvarjeno — ' || COALESCE(NEW.listing_title, 'oglas'),
          'Sklic: ' || COALESCE(NEW.payment_ref, '—'),
          'markets.html');

  -- Obvesti tudi admina (oba dovoljena e-naslova), da čaka novo
  -- naročilo na obdelavo (plačilna navodila / potrditev plačila).
  FOR v_admin_id IN
    SELECT id FROM auth.users
     WHERE lower(email) IN ('metals-trade@protonmail.com', 'jani.zibert@gazela.si')
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, link)
    VALUES (v_admin_id, 'admin_new_order',
            'Novo naročilo — ' || COALESCE(NEW.listing_title, 'oglas'),
            'Sklic ' || COALESCE(NEW.payment_ref, '—') || ' · ' || NEW.currency || ' ' || NEW.amount || ' čaka na obdelavo v Nastavitve → Naročila.',
            'admin.html');
  END LOOP;

  RETURN NEW;
END; $$;

-- Sprožilec sam (trg_transaction_insert) ostane nespremenjen — samo
-- funkcija, ki jo kliče, je zdaj dopolnjena.
