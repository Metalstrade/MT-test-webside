-- ─────────────────────────────────────────────
-- ESCROW TRANSACTIONS — Metals Trading
-- Zaženi v Supabase SQL Editor
-- ─────────────────────────────────────────────

create table if not exists transactions (
  id              uuid primary key default gen_random_uuid(),
  listing_id      uuid references listings(id) on delete set null,
  buyer_id        uuid not null references auth.users(id),
  seller_id       uuid not null references auth.users(id),
  listing_title   text not null,
  amount          numeric(12,2) not null,
  currency        text not null default 'EUR',
  fee_pct         numeric(5,2) not null default 2.00,
  fee_amount      numeric(12,2) generated always as (round(amount * fee_pct / 100, 2)) stored,
  seller_payout   numeric(12,2) generated always as (round(amount - (amount * fee_pct / 100), 2)) stored,
  payment_ref     text unique not null,
  status          text not null default 'pending_payment',
  -- pending_payment → payment_received → goods_shipped → goods_received → completed
  -- ali: disputed | cancelled
  buyer_notes     text,
  admin_notes     text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

alter table transactions enable row level security;

create policy "tx_buyer_select"  on transactions for select using (buyer_id  = auth.uid());
create policy "tx_seller_select" on transactions for select using (seller_id = auth.uid());
create policy "tx_buyer_insert"  on transactions for insert with check (buyer_id = auth.uid());
create policy "tx_buyer_update"  on transactions for update using (buyer_id = auth.uid());

-- ── Admin: vse transakcije ──
create or replace function admin_get_transactions()
returns setof transactions
language sql security definer
as $$
  select * from transactions order by created_at desc;
$$;

-- ── Admin: posodobi status ──
create or replace function admin_update_transaction(p_id uuid, p_status text, p_notes text default null)
returns json
language plpgsql security definer
as $$
declare v_email text;
begin
  select email into v_email from auth.users where id = auth.uid();
  if lower(v_email) not in ('metals-trade@protonmail.com', 'jani.zibert@gazela.si') then
    return json_build_object('error', 'Unauthorized');
  end if;
  update transactions set
    status      = p_status,
    admin_notes = coalesce(p_notes, admin_notes),
    updated_at  = now()
  where id = p_id;
  return json_build_object('ok', true);
end;
$$;

-- ── Kupec: potrdi prejem blaga ──
create or replace function buyer_confirm_receipt(p_id uuid)
returns json
language plpgsql security definer
as $$
begin
  update transactions set
    status     = 'goods_received',
    updated_at = now()
  where id = p_id and buyer_id = auth.uid() and status = 'goods_shipped';
  if not found then
    return json_build_object('error', 'Transakcija ni najdena ali napačen status');
  end if;
  return json_build_object('ok', true);
end;
$$;
