-- ============================================================
-- METALS TRADING — AGENT ZA DRAŽBE (proxy bidding, kot na OpenLane)
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
--
-- Kupec lahko namesto ročne ponudbe vklopi "agenta" in nastavi
-- najvišjo ceno, do katere je pripravljen plačati. Kadar ga kdo
-- prehiti (ročno ali z drugim agentom), strežnik SAM odda naslednjo
-- potrebno protiponudbo v njegovem imenu — brez da bi moral biti
-- uporabnik prisoten — vse do njegove nastavljene najvišje cene.
--
-- Opomba: natančne definicije obstoječega place_bid() nimam na
-- voljo lokalno (ustvarjen je bil neposredno v nadzorni plošči), zato
-- ga ta migracija NE spreminja. Namesto tega agent deluje kot ločen,
-- dodaten mehanizem: po vsaki spremembi listings.current_bid (ne
-- glede na to, ali jo je povzročil ročen place_bid ali prejšnji
-- korak agenta) se sproži primerjava z aktivnimi agenti in po
-- potrebi odda nova protiponudba. Ujema se s shemo tabele "bids"
-- (listing_id, user_id, amount), ki jo že uporablja stran "Moje
-- ponudbe", zato se agent-ponudbe prikažejo enako kot ročne.
-- ============================================================

-- 1. Tabela agentov (ena aktivna nastavitev na kupca na oglas)
CREATE TABLE IF NOT EXISTS public.auction_agents (
  id          uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  listing_id  uuid NOT NULL REFERENCES public.listings(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL,
  max_amount  numeric NOT NULL CHECK (max_amount > 0),
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now(),
  UNIQUE (listing_id, user_id)
);

ALTER TABLE public.auction_agents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "own_agent_select" ON public.auction_agents;
CREATE POLICY "own_agent_select" ON public.auction_agents
  FOR SELECT USING (user_id = auth.uid());
-- Vpis/sprememba gre izključno skozi spodnje SECURITY DEFINER RPC-je
-- (ki preverijo lastništvo, rezervno ceno ipd.), zato ni INSERT/UPDATE
-- politike za navadne uporabnike.

-- 2. Minimalni korak zvišanja ponudbe — vedno vsaj 2% trenutne cene
--    (min. $1), da je število korakov v verižnem "dvoboju" dveh
--    agentov omejeno (geometrijska, ne linearna rast). Prag/odstotek
--    po potrebi prilagodite poslovni logiki.
CREATE OR REPLACE FUNCTION public._bid_increment(p_current numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(1, round(COALESCE(p_current, 0) * 0.02, 2));
$$;

-- 3. Jedro: en korak razreševanja agentov za oglas. Če obstaja
--    aktiven agent, ki trenutno NI vodilni, pa ima max_amount višji
--    od trenutne ponudbe, ta agent odda minimalno potrebno
--    protiponudbo (do svojega maksimuma). Ker gre za navaden UPDATE
--    na listings.current_bid, se ob verigi dveh agentov funkcija
--    prek trigerja spodaj samodejno znova sproži, dokler eden od
--    agentov ne doseže svojega maksimuma (enak izid kot klasični
--    "proxy bidding", le izračunan po majhnih korakih namesto z eno
--    formulo — matematično zagotovljeno konča, saj se current_bid
--    pri vsakem koraku strogo poveča in je navzgor omejen).
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

  v_next := LEAST(
    v_agent.max_amount,
    GREATEST(COALESCE(v_listing.current_bid, 0), COALESCE(v_listing.reserve_price, 0))
      + public._bid_increment(COALESCE(v_listing.current_bid, 0))
  );

  IF v_next > COALESCE(v_listing.current_bid, 0) THEN
    INSERT INTO public.bids (listing_id, user_id, amount)
    VALUES (p_listing_id, v_agent.user_id, v_next);

    UPDATE public.listings
       SET current_bid = v_next, current_bidder_id = v_agent.user_id
     WHERE id = p_listing_id;
  END IF;
END; $$;

-- 4. Triger: po vsaki spremembi current_bid (ročna ponudba ALI
--    prejšnji korak agenta) znova preveri, ali kak agent lahko in
--    mora protiponuditi. To omogoča verižno "licitiranje" med agenti
--    brez prisotnosti uporabnikov.
CREATE OR REPLACE FUNCTION public._trg_resolve_auction_agents()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.current_bid IS DISTINCT FROM OLD.current_bid THEN
    PERFORM public._resolve_auction_agents(NEW.id);
  END IF;
  RETURN NULL;
END; $$;

DROP TRIGGER IF EXISTS trg_resolve_auction_agents ON public.listings;
CREATE TRIGGER trg_resolve_auction_agents
  AFTER UPDATE ON public.listings
  FOR EACH ROW
  EXECUTE FUNCTION public._trg_resolve_auction_agents();

-- 5. RPC: vklopi / posodobi agenta (zviša njegovo najvišjo ceno)
CREATE OR REPLACE FUNCTION public.set_auction_agent(p_listing_id uuid, p_max_amount numeric)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_uid     uuid;
  v_listing RECORD;
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

  INSERT INTO public.auction_agents (listing_id, user_id, max_amount, active, updated_at)
  VALUES (p_listing_id, v_uid, p_max_amount, true, now())
  ON CONFLICT (listing_id, user_id)
  DO UPDATE SET max_amount = EXCLUDED.max_amount, active = true, updated_at = now();

  -- Takoj preveri, ali mora agent nemudoma protiponuditi (npr. nekdo
  -- drug je trenutno vodilni).
  PERFORM public._resolve_auction_agents(p_listing_id);

  RETURN json_build_object('success', true);
END; $$;

REVOKE EXECUTE ON FUNCTION public.set_auction_agent(uuid, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_auction_agent(uuid, numeric) TO authenticated;

-- 6. RPC: izklopi agenta (preneha samodejno bidati)
CREATE OR REPLACE FUNCTION public.cancel_auction_agent(p_listing_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_uid uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN RETURN json_build_object('error', 'not_authenticated'); END IF;
  UPDATE public.auction_agents SET active = false, updated_at = now()
   WHERE listing_id = p_listing_id AND user_id = v_uid;
  RETURN json_build_object('success', true);
END; $$;

REVOKE EXECUTE ON FUNCTION public.cancel_auction_agent(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.cancel_auction_agent(uuid) TO authenticated;

-- 7. RPC: stanje LASTNEGA agenta za ta oglas (za prikaz v obrazcu)
CREATE OR REPLACE FUNCTION public.get_my_auction_agent(p_listing_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_uid uuid; v_row RECORD;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN RETURN json_build_object('active', false); END IF;
  SELECT active, max_amount INTO v_row FROM public.auction_agents
   WHERE listing_id = p_listing_id AND user_id = v_uid;
  IF v_row IS NULL THEN RETURN json_build_object('active', false); END IF;
  RETURN json_build_object('active', v_row.active, 'max_amount', v_row.max_amount);
END; $$;

REVOKE EXECUTE ON FUNCTION public.get_my_auction_agent(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_my_auction_agent(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
