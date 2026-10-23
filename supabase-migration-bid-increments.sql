-- ============================================================
-- METALS TRADING — STOPNJEVANI KORAK DVIGA PONUDBE
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
--
-- Prej je lahko kupec drugega prehitel za samo $1. Zdaj velja
-- najmanjši dvig glede na trenutno ponudbo:
--     pod $100          →  $5
--     $100 – $999       →  $10
--     $1.000 – $4.999   →  $50
--     $5.000 – $24.999  →  $100
--     $25.000 – $99.999 →  $250
--     $100.000 in več   →  $500
--
-- Uveljavlja ga BAZA (ne le brskalnik): sprožilec BEFORE UPDATE na
-- listings zavrne vsak dvig current_bid, ki je manjši od koraka —
-- ne glede na to, ali pride iz place_bid() (katerega kode nimamo
-- lokalno, zato ga ne spreminjamo), iz neposrednega REST klica ali
-- od drugod. Ista tabela velja tudi za agenta za dražbe.
-- ============================================================

-- 1. Tabela korakov (zamenja prejšnjih 2 % / min $1)
CREATE OR REPLACE FUNCTION public._bid_increment(p_current numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN COALESCE(p_current, 0) < 100 THEN 5
    WHEN p_current < 1000            THEN 10
    WHEN p_current < 5000            THEN 50
    WHEN p_current < 25000           THEN 100
    WHEN p_current < 100000          THEN 250
    ELSE 500
  END::numeric;
$$;

-- 2. Varovalo v bazi: vsak dvig ponudbe mora biti vsaj za korak,
--    in (razen pri "Kupi takoj") nižji od cene "Kupi takoj".
CREATE OR REPLACE FUNCTION public._trg_enforce_bid_increment()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_min numeric;
BEGIN
  -- Ni dviga (npr. ponastavitev ob urejanju oglasa) → ni preverjanja.
  IF NEW.current_bid IS NULL OR NEW.current_bid <= COALESCE(OLD.current_bid, 0) THEN
    RETURN NEW;
  END IF;

  -- "Kupi takoj" (buy_now_auction) dražbo hkrati zaključi — fiksna
  -- cena, korak ne velja.
  IF NEW.auction_end_at IS DISTINCT FROM OLD.auction_end_at
     AND NEW.auction_end_at <= now() THEN
    RETURN NEW;
  END IF;

  -- Agent sme zadnji dvig narediti do svojega maksimuma, tudi če je
  -- to manj kot cel korak (enako kot eBay proxy). Zastavico nastavi
  -- izključno _resolve_auction_agents (uporabnik je prek REST ne more).
  IF current_setting('mt.agent_bid', true) = '1' THEN
    RETURN NEW;
  END IF;

  IF NEW.buy_now_price IS NOT NULL AND NEW.current_bid >= NEW.buy_now_price THEN
    RAISE EXCEPTION 'bid_above_buy_now:%', NEW.buy_now_price USING ERRCODE = 'P0001';
  END IF;

  IF COALESCE(OLD.current_bid, 0) = 0 THEN
    v_min := COALESCE(NEW.reserve_price, 0);
  ELSE
    v_min := OLD.current_bid + public._bid_increment(OLD.current_bid);
  END IF;

  IF NEW.current_bid < v_min THEN
    RAISE EXCEPTION 'bid_increment_too_low:%', v_min USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_enforce_bid_increment ON public.listings;
CREATE TRIGGER trg_enforce_bid_increment
  BEFORE UPDATE OF current_bid ON public.listings
  FOR EACH ROW
  EXECUTE FUNCTION public._trg_enforce_bid_increment();

-- 3. Agent: prvi dvig = rezervna cena, nato trenutna + korak (do
--    maksimuma). Zastavica mt.agent_bid označi, da gre za agentov dvig.
CREATE OR REPLACE FUNCTION public._resolve_auction_agents(p_listing_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_listing RECORD;
  v_agent   RECORD;
  v_next    numeric;
BEGIN
  SELECT * INTO v_listing FROM public.listings WHERE id = p_listing_id FOR UPDATE;
  IF v_listing IS NULL OR v_listing.sale_type <> 'auction' THEN RETURN; END IF;
  IF v_listing.auction_end_at IS NOT NULL AND v_listing.auction_end_at <= now() THEN RETURN; END IF;

  SELECT a.user_id, a.max_amount INTO v_agent
    FROM public.auction_agents a
   WHERE a.listing_id = p_listing_id
     AND a.active
     AND a.user_id IS DISTINCT FROM v_listing.current_bidder_id
     AND a.max_amount > COALESCE(v_listing.current_bid, 0)
   ORDER BY a.max_amount DESC, a.updated_at ASC
   LIMIT 1;

  IF v_agent IS NULL THEN RETURN; END IF;

  IF COALESCE(v_listing.current_bid, 0) = 0 THEN
    v_next := GREATEST(COALESCE(v_listing.reserve_price, 0), public._bid_increment(0));
  ELSE
    v_next := v_listing.current_bid + public._bid_increment(v_listing.current_bid);
  END IF;
  v_next := LEAST(v_agent.max_amount, v_next);

  IF v_next > COALESCE(v_listing.current_bid, 0) THEN
    INSERT INTO public.bids (listing_id, user_id, amount)
    VALUES (p_listing_id, v_agent.user_id, v_next);

    PERFORM set_config('mt.agent_bid', '1', true);
    UPDATE public.listings
       SET current_bid = v_next, current_bidder_id = v_agent.user_id
     WHERE id = p_listing_id;
    PERFORM set_config('mt.agent_bid', '', true);
  END IF;
END; $$;

-- 4. set_auction_agent: maksimum mora biti vsaj najmanjša naslednja
--    ponudba in nižji od cene "Kupi takoj".
CREATE OR REPLACE FUNCTION public.set_auction_agent(p_listing_id uuid, p_max_amount numeric)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_uid     uuid;
  v_listing RECORD;
  v_min     numeric;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN RETURN json_build_object('error', 'not_authenticated'); END IF;
  IF p_max_amount IS NULL OR p_max_amount <= 0 THEN RETURN json_build_object('error', 'invalid_amount'); END IF;

  SELECT * INTO v_listing FROM public.listings WHERE id = p_listing_id FOR UPDATE;
  IF v_listing IS NULL THEN RETURN json_build_object('error', 'listing_not_found'); END IF;
  IF v_listing.sale_type <> 'auction' THEN RETURN json_build_object('error', 'not_an_auction'); END IF;
  IF v_listing.user_id = v_uid THEN RETURN json_build_object('error', 'own_listing'); END IF;
  IF v_listing.auction_end_at IS NOT NULL AND v_listing.auction_end_at <= now() THEN
    RETURN json_build_object('error', 'auction_ended');
  END IF;
  IF v_listing.reserve_price IS NOT NULL AND p_max_amount < v_listing.reserve_price THEN
    RETURN json_build_object('error', 'below_reserve', 'reserve_price', v_listing.reserve_price);
  END IF;
  IF v_listing.buy_now_price IS NOT NULL AND p_max_amount >= v_listing.buy_now_price THEN
    RETURN json_build_object('error', 'above_buy_now', 'buy_now_price', v_listing.buy_now_price);
  END IF;
  IF COALESCE(v_listing.current_bid, 0) > 0
     AND v_listing.current_bidder_id IS DISTINCT FROM v_uid THEN
    v_min := v_listing.current_bid + public._bid_increment(v_listing.current_bid);
    IF p_max_amount < v_min THEN
      RETURN json_build_object('error', 'below_min_bid', 'min_bid', v_min);
    END IF;
  END IF;

  INSERT INTO public.auction_agents (listing_id, user_id, max_amount, active, updated_at)
  VALUES (p_listing_id, v_uid, p_max_amount, true, now())
  ON CONFLICT (listing_id, user_id)
  DO UPDATE SET max_amount = EXCLUDED.max_amount, active = true, updated_at = now();

  PERFORM public._resolve_auction_agents(p_listing_id);

  RETURN json_build_object('success', true);
END; $$;

REVOKE EXECUTE ON FUNCTION public.set_auction_agent(uuid, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_auction_agent(uuid, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
