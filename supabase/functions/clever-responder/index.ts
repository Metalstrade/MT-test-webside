const SYMBOLS = [
  // Commodities
  { s: 'GC=F',      label: 'AU'      },
  { s: 'SI=F',      label: 'AG'      },
  { s: 'HG=F',      label: 'CU'      },
  { s: 'CL=F',      label: 'OIL'     },
  { s: 'NG=F',      label: 'NATGAS'  },
  { s: 'PL=F',      label: 'PLAT'    },
  // US Stocks / Indices
  { s: '^GSPC',     label: 'S&P'     },
  { s: '^IXIC',     label: 'NDQ'     },
  { s: '^DJI',      label: 'DJI'     },
  { s: '^RUT',      label: 'RUT'     },
  { s: 'TSLA',      label: 'TSLA'    },
  { s: 'AAPL',      label: 'AAPL'    },
  { s: 'AMZN',      label: 'AMZN'    },
  { s: 'META',      label: 'META'    },
  // Crypto
  { s: 'BTC-USD',   label: 'BTC'     },
  { s: 'ETH-USD',   label: 'ETH'     },
  { s: 'XRP-USD',   label: 'XRP'     },
  { s: 'SOL-USD',   label: 'SOL'     },
  { s: 'BNB-USD',   label: 'BNB'     },
  { s: 'DOGE-USD',  label: 'DOGE'    },
  { s: 'LTC-USD',   label: 'LTC'     },
  { s: 'ADA-USD',   label: 'ADA'     },
  // Currencies
  { s: 'EURUSD=X',  label: 'EUR/USD' },
  { s: 'USDJPY=X',  label: 'USD/JPY' },
  { s: 'GBPUSD=X',  label: 'GBP/USD' },
  { s: 'AUDUSD=X',  label: 'AUD/USD' },
  { s: 'USDCHF=X',  label: 'USD/CHF' },
  { s: 'USDCAD=X',  label: 'USD/CAD' },
];

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS });
  }

  const results = await Promise.all(
    SYMBOLS.map(async ({ s, label }) => {
      try {
        const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(s)}?interval=1d&range=2d`;
        const res = await fetch(url, {
          headers: { 'User-Agent': 'Mozilla/5.0' },
        });
        const json = await res.json();
        const meta = json?.chart?.result?.[0]?.meta;
        const price = meta?.regularMarketPrice ?? null;
        const prev  = meta?.chartPreviousClose ?? meta?.previousClose ?? null;
        const pct   = (price && prev) ? ((price - prev) / prev) * 100 : null;
        return {
          label,
          price: price !== null ? Math.round(price * 100) / 100 : null,
          pct:   pct   !== null ? Math.round(pct   * 100) / 100 : null,
        };
      } catch {
        return { label, price: null, pct: null };
      }
    })
  );

  return new Response(JSON.stringify(results), {
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
