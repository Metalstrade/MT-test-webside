-- ============================================================
-- METALS TRADING — "KUPI TAKOJ" (BUY NOW) NA DRAŽBAH
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
--
-- Prodajalec lahko ob objavi dražbe neobvezno nastavi fiksno "kupi
-- takoj" ceno. Kupec lahko kadarkoli pred koncem dražbe namesto
-- oddaje ponudbe takoj kupi po tej ceni — dražba se takoj zaključi
-- v njegovo korist (current_bid/current_bidder_id/auction_end_at se
-- postavijo enako, kot če bi dražbo "zmagal", zato se naprej uporabi
-- isti tok plačila kot pri zaključeni zmagani dražbi).
-- ============================================================

ALTER TABLE listings ADD COLUMN IF NOT EXISTS buy_now_price numeric;

CREATE OR REPLACE FUNCTION public.buy_now_auction(p_listing_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_uid     uuid;
  v_listing RECORD;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', 'not_authenticated');
  END IF;

  -- Vrstico zaklenemo (FOR UPDATE), da dve sočasni "kupi takoj" /
  -- place_bid zahtevi za isti oglas ne moreta obe uspeti.
  SELECT * INTO v_listing FROM public.listings WHERE id = p_listing_id FOR UPDATE;
  IF v_listing IS NULL THEN
    RETURN json_build_object('error', 'listing_not_found');
  END IF;

  IF v_listing.sale_type <> 'auction' THEN
    RETURN json_build_object('error', 'not_an_auction');
  END IF;

  IF v_listing.user_id = v_uid THEN
    RETURN json_build_object('error', 'own_listing');
  END IF;

  IF v_listing.buy_now_price IS NULL OR v_listing.buy_now_price <= 0 THEN
    RETURN json_build_object('error', 'no_buy_now_price');
  END IF;

  IF v_listing.auction_end_at IS NOT NULL AND v_listing.auction_end_at <= now() THEN
    RETURN json_build_object('error', 'auction_ended');
  END IF;

  UPDATE public.listings
     SET current_bid       = v_listing.buy_now_price,
         current_bidder_id = v_uid,
         winner_id         = v_uid,
         winning_bid       = v_listing.buy_now_price,
         auction_end_at    = now()
   WHERE id = p_listing_id;

  RETURN json_build_object('success', true, 'amount', v_listing.buy_now_price);
END; $$;

REVOKE EXECUTE ON FUNCTION public.buy_now_auction(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.buy_now_auction(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
