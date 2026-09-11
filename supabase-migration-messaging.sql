-- ============================================================
-- METALS TRADING — MESSAGING & NOTIFICATIONS MIGRATION
-- Zaženi v Supabase SQL editorju:
-- https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
--
-- Ustvari:
--   • conversations  — pogovor kupec↔prodajalec, vezan na oglas
--   • messages       — posamezna sporočila v pogovoru
--   • notifications  — in-app obvestila (zvonec)
--   • triggerji, ki ob sporočilu / ponudbi / prelicitiranju / prodaji
--     samodejno ustvarijo obvestilo prejemniku
-- Vse tabele so vključene v realtime publikacijo (živo osveževanje).
-- ============================================================

-- ══ 1. TABELE ══════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.conversations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id      uuid NOT NULL REFERENCES public.listings(id) ON DELETE CASCADE,
  listing_name    text,
  buyer_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  seller_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_message_at timestamptz NOT NULL DEFAULT now(),
  last_message    text,
  buyer_unread    int NOT NULL DEFAULT 0,
  seller_unread   int NOT NULL DEFAULT 0,
  UNIQUE (listing_id, buyer_id)
);

CREATE TABLE IF NOT EXISTS public.messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body            text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 4000),
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type        text NOT NULL,          -- 'message' | 'bid' | 'outbid' | 'sale' | 'purchase'
  title       text NOT NULL,
  body        text,
  link        text,
  read        boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_conv_buyer   ON public.conversations(buyer_id);
CREATE INDEX IF NOT EXISTS idx_conv_seller  ON public.conversations(seller_id);
CREATE INDEX IF NOT EXISTS idx_msg_conv     ON public.messages(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_notif_user   ON public.notifications(user_id, read, created_at DESC);

-- ══ 2. RLS ═════════════════════════════════════════════════

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- ── conversations: le udeleženca bereta/posodabljata, kupec ustvari ──
DROP POLICY IF EXISTS "conv_select" ON public.conversations;
CREATE POLICY "conv_select" ON public.conversations
  FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

DROP POLICY IF EXISTS "conv_insert" ON public.conversations;
CREATE POLICY "conv_insert" ON public.conversations
  FOR INSERT WITH CHECK (auth.uid() = buyer_id AND auth.uid() <> seller_id);

DROP POLICY IF EXISTS "conv_update" ON public.conversations;
CREATE POLICY "conv_update" ON public.conversations
  FOR UPDATE USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

-- ── messages: le udeleženca pogovora bereta; pošiljatelj vstavi ──
DROP POLICY IF EXISTS "msg_select" ON public.messages;
CREATE POLICY "msg_select" ON public.messages
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.conversations c
            WHERE c.id = conversation_id
              AND (auth.uid() = c.buyer_id OR auth.uid() = c.seller_id))
  );

DROP POLICY IF EXISTS "msg_insert" ON public.messages;
CREATE POLICY "msg_insert" ON public.messages
  FOR INSERT WITH CHECK (
    auth.uid() = sender_id
    AND EXISTS (SELECT 1 FROM public.conversations c
                WHERE c.id = conversation_id
                  AND (auth.uid() = c.buyer_id OR auth.uid() = c.seller_id))
  );

-- ── notifications: le lastnik bere/označi prebrano. Vstavljajo TRIGGERJI ──
DROP POLICY IF EXISTS "notif_select" ON public.notifications;
CREATE POLICY "notif_select" ON public.notifications
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "notif_update" ON public.notifications;
CREATE POLICY "notif_update" ON public.notifications
  FOR UPDATE USING (auth.uid() = user_id);

-- ══ 3. TRIGGER: novo sporočilo ═════════════════════════════
-- Posodobi pogovor (zadnje sporočilo, števec neprebranih) in ustvari
-- obvestilo prejemniku. SECURITY DEFINER → obide RLS na notifications.

CREATE OR REPLACE FUNCTION public.on_message_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_conv      public.conversations;
  v_recipient uuid;
BEGIN
  SELECT * INTO v_conv FROM public.conversations WHERE id = NEW.conversation_id;

  IF NEW.sender_id = v_conv.buyer_id THEN
    v_recipient := v_conv.seller_id;
    UPDATE public.conversations
       SET last_message = NEW.body, last_message_at = NEW.created_at,
           seller_unread = seller_unread + 1
     WHERE id = NEW.conversation_id;
  ELSE
    v_recipient := v_conv.buyer_id;
    UPDATE public.conversations
       SET last_message = NEW.body, last_message_at = NEW.created_at,
           buyer_unread = buyer_unread + 1
     WHERE id = NEW.conversation_id;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, link)
  VALUES (v_recipient, 'message',
          'Novo sporočilo — ' || COALESCE(v_conv.listing_name, 'oglas'),
          left(NEW.body, 140),
          'markets.html?conversation=' || NEW.conversation_id);

  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_message_insert ON public.messages;
CREATE TRIGGER trg_message_insert
  AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.on_message_insert();

-- ══ 4. TRIGGER: ponudba / prelicitiranje ═══════════════════
-- Ko place_bid posodobi listings.current_bidder_id, obvesti prodajalca
-- (nova ponudba) in prejšnjega ponudnika (prelicitiran).

CREATE OR REPLACE FUNCTION public.on_bid_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NEW.current_bidder_id IS DISTINCT FROM OLD.current_bidder_id
     AND NEW.current_bidder_id IS NOT NULL THEN

    -- prodajalcu
    INSERT INTO public.notifications (user_id, type, title, body, link)
    VALUES (NEW.user_id, 'bid',
            'Nova ponudba — ' || COALESCE(NEW.name, 'vaš oglas'),
            'Trenutna ponudba: $' || NEW.current_bid,
            'markets.html');

    -- prejšnjemu ponudniku (prelicitiran)
    IF OLD.current_bidder_id IS NOT NULL
       AND OLD.current_bidder_id <> NEW.current_bidder_id THEN
      INSERT INTO public.notifications (user_id, type, title, body, link)
      VALUES (OLD.current_bidder_id, 'outbid',
              'Prelicitirani ste — ' || COALESCE(NEW.name, 'oglas'),
              'Nova vodilna ponudba: $' || NEW.current_bid,
              'markets.html');
    END IF;
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_bid_update ON public.listings;
CREATE TRIGGER trg_bid_update
  AFTER UPDATE OF current_bidder_id ON public.listings
  FOR EACH ROW EXECUTE FUNCTION public.on_bid_update();

-- ══ 5. TRIGGER: prodaja / nakup ════════════════════════════
-- Ob novi transakciji obvesti prodajalca (prodano) in kupca (naročilo).

CREATE OR REPLACE FUNCTION public.on_transaction_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
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

  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_transaction_insert ON public.transactions;
CREATE TRIGGER trg_transaction_insert
  AFTER INSERT ON public.transactions
  FOR EACH ROW EXECUTE FUNCTION public.on_transaction_insert();

-- ══ 6. REALTIME ════════════════════════════════════════════
-- Doda tabele v realtime publikacijo (varno ponovi, če že obstajajo).

DO $$
BEGIN
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;      EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.conversations; EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications; EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;

-- ══ 7. RPC: označi pogovor kot prebran ═════════════════════
-- Ponastavi števec neprebranih za klicoča (kupca ali prodajalca).

CREATE OR REPLACE FUNCTION public.mark_conversation_read(p_conversation_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_conv public.conversations;
BEGIN
  SELECT * INTO v_conv FROM public.conversations WHERE id = p_conversation_id;
  IF v_conv IS NULL THEN RETURN; END IF;

  IF auth.uid() = v_conv.buyer_id THEN
    UPDATE public.conversations SET buyer_unread = 0 WHERE id = p_conversation_id;
  ELSIF auth.uid() = v_conv.seller_id THEN
    UPDATE public.conversations SET seller_unread = 0 WHERE id = p_conversation_id;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.mark_conversation_read(uuid) TO authenticated;
