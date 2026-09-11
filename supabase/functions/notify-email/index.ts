// ============================================================
// notify-email — pošlje e-pošto ob novem in-app obvestilu
//
// Sproži ga Supabase Database Webhook na tabeli `notifications`
// (dogodek INSERT). Webhook pošlje novo vrstico, funkcija poišče
// e-poštni naslov prejemnika (service role) in pošlje e-pošto prek
// Resend.
//
// Potrebne skrivnosti (Project → Edge Functions → Secrets):
//   RESEND_API_KEY   — API ključ iz resend.com
//   NOTIFY_FROM      — potrjen pošiljatelj, npr. "Metals Trading <obvestila@metals-trade.com>"
//   NOTIFY_SITE_URL  — osnovni URL, npr. "https://metals-trade.com" (za povezave v e-pošti)
//   WEBHOOK_SECRET   — (neobvezno) skrivnost; če nastavljena, mora webhook poslati
//                      glavo  x-webhook-secret  z isto vrednostjo
//
// SUPABASE_URL in SUPABASE_SERVICE_ROLE_KEY sta samodejno na voljo.
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY') ?? '';
const NOTIFY_FROM    = Deno.env.get('NOTIFY_FROM') ?? 'Metals Trading <onboarding@resend.dev>';
const SITE_URL       = Deno.env.get('NOTIFY_SITE_URL') ?? 'https://metals-trade.com';
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET') ?? '';

const admin = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

function emailHtml(title: string, body: string, link: string) {
  const safe = (s: string) => (s ?? '').replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c]!));
  return `<!doctype html><html><body style="margin:0;background:#0D1117;font-family:Inter,Arial,sans-serif;color:#E8EEF2;">
    <div style="max-width:520px;margin:0 auto;padding:32px 24px;">
      <div style="font-size:20px;font-weight:700;color:#C9A227;letter-spacing:0.02em;margin-bottom:24px;">METALS&nbsp;TRADING</div>
      <div style="background:#141C24;border:1px solid rgba(201,162,39,0.18);border-radius:10px;padding:28px;">
        <h1 style="font-size:19px;margin:0 0 10px;color:#E8EEF2;">${safe(title)}</h1>
        <p style="font-size:14px;line-height:1.6;color:#8FA3B1;margin:0 0 24px;">${safe(body)}</p>
        <a href="${SITE_URL}/${safe(link)}" style="display:inline-block;background:#C9A227;color:#0D1117;text-decoration:none;font-weight:600;font-size:14px;padding:11px 22px;border-radius:6px;">Odpri na platformi →</a>
      </div>
      <p style="font-size:11px;color:#5A6E7A;margin-top:22px;text-align:center;">
        To sporočilo ste prejeli, ker imate račun na Metals Trading.
      </p>
    </div></body></html>`;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });

  if (WEBHOOK_SECRET && req.headers.get('x-webhook-secret') !== WEBHOOK_SECRET) {
    return new Response('Unauthorized', { status: 401 });
  }

  let payload: any;
  try { payload = await req.json(); } catch { return new Response('Bad JSON', { status: 400 }); }

  const n = payload?.record;
  if (!n || !n.user_id) return new Response('No record', { status: 200 });

  if (!RESEND_API_KEY) {
    console.error('RESEND_API_KEY ni nastavljen — e-pošta preskočena.');
    return new Response('Email disabled', { status: 200 });
  }

  // poišči e-pošto prejemnika
  const { data: userRes, error: userErr } = await admin.auth.admin.getUserById(n.user_id);
  if (userErr || !userRes?.user?.email) {
    console.error('Ni e-pošte za uporabnika', n.user_id, userErr);
    return new Response('No email', { status: 200 });
  }
  const to = userRes.user.email;

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: NOTIFY_FROM,
      to,
      subject: n.title || 'Novo obvestilo — Metals Trading',
      html: emailHtml(n.title || 'Novo obvestilo', n.body || '', n.link || ''),
    }),
  });

  if (!res.ok) {
    const t = await res.text();
    console.error('Resend napaka:', res.status, t);
    return new Response('Send failed', { status: 200 });
  }
  return new Response('OK', { status: 200 });
});
