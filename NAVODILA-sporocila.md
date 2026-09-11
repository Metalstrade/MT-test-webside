# Sporočila & obveščanje — navodila za namestitev

Funkciji **sporočila kupec↔prodajalec** in **obvestila (zvonec + e-pošta)** sta zgrajeni
v `markets.html`. Da začneta delovati, je treba pognati eno SQL migracijo. E-pošta je
neobvezen dodaten sloj.

> **Vrstni red je pomemben:** najprej poženi SQL (korak 1), šele nato objavi frontend
> na GitHub. Če objaviš frontend prej, bodo gumbi za sporočila javljali napako, ker
> tabele še ne obstajajo.

---

## Korak 1 — SQL migracija (OBVEZNO, ~30 s)

1. Odpri SQL editor:
   https://supabase.com/dashboard/project/xurgxkrnmutmocqbjffw/sql
2. Prilepi celotno vsebino datoteke **`supabase-migration-messaging.sql`** in klikni **Run**.

To ustvari tabele `conversations`, `messages`, `notifications`, vse varnostne (RLS)
politike, samodejne triggerje (novo sporočilo, ponudba, prelicitiranje, prodaja) in
vklopi realtime (živo osveževanje). Po tem koraku **in-app sporočila in zvonec delujeta.**

---

## Korak 2 — E-pošta (NEOBVEZNO)

In-app obvestila delujejo brez tega. Ta korak doda še e-pošto, ko je uporabnik odsoten.

### 2a. Resend račun
1. Registriraj se na https://resend.com (brezplačni plan zadošča za začetek).
2. Dodaj in potrdi domeno `metals-trade.com` (DNS zapisi) — ali za test uporabi
   privzetega pošiljatelja `onboarding@resend.dev`.
3. Ustvari **API ključ**.

### 2b. Naloži edge funkcijo
Datoteka je že v repozitoriju: `supabase/functions/notify-email/index.ts`.

```bash
supabase login
supabase functions deploy notify-email --project-ref xurgxkrnmutmocqbjffw
```

### 2c. Nastavi skrivnosti (Project → Edge Functions → Secrets)
- `RESEND_API_KEY` = ključ iz Resend
- `NOTIFY_FROM` = `Metals Trading <obvestila@metals-trade.com>` (ali `onboarding@resend.dev` za test)
- `NOTIFY_SITE_URL` = `https://metals-trade.com`
- `WEBHOOK_SECRET` = poljubna skrivnost (npr. dolg naključni niz)

### 2d. Database Webhook
Database → Webhooks → **Create webhook**:
- Tabela: `notifications`
- Dogodek: **Insert**
- Tip: **Supabase Edge Functions** → izberi `notify-email`
- HTTP glava: `x-webhook-secret` = ista vrednost kot `WEBHOOK_SECRET`

Po tem se ob vsakem novem obvestilu prejemniku pošlje tudi e-pošta.

---

## Kaj deluje po namestitvi

- **Gumb „✉ Sporočilo prodajalcu“** na vsakem oglasu (za ne-lastnike) → odpre pogovor.
- **Zavihek „Sporočila“** — seznam pogovorov + klepet v živo (realtime).
- **Zvonec** v navigaciji — števec neprebranih, seznam obvestil, „označi vse prebrano“.
- **Samodejna obvestila** za: novo sporočilo, novo ponudbo, prelicitiranje, prodajo/nakup.
- Klik na obvestilo skoči na ustrezen pogovor ali trg.

## Opombe
- Prijava je pogoj — neprijavljeni uporabnik vidi poziv za prijavo.
- Prodajalec je določen po `listings.user_id` (obstoječe polje).
- E-poštni naslov sogovornika se nikoli ne razkrije v brskalniku (pošiljanje je strežniško).
