/**
 * propicks_discover.mjs — Strategy discovery from ProPicks landing page
 */

const log = (...a) => console.log(`[Discover ${new Date().toLocaleTimeString('tr-TR')}]`, ...a);

const BASE_URL    = 'https://www.investing.com';
const PROPICKS_URL = `${BASE_URL}/pro/propicks`;

// ── SEED FALLBACK ─────────────────────────────────────────────────────────────
const SEED_STRATEGIES = [
  { slug: 'beat-sp-500',      name: 'Beat the S&P 500',    market: 'US' },
  { slug: 'tech-titans',      name: 'Tech Titans',          market: 'US' },
  { slug: 'top-value-stocks', name: 'Top Value Stocks',     market: 'US' },
  { slug: 'midcap-movers',    name: 'Mid-Cap Movers',       market: 'US' },
  { slug: 'dominate-the-dow', name: 'Dominate the Dow',     market: 'US' },
  { slug: 'beat-dax',         name: 'Beat the DAX',         market: 'EU' },
  { slug: 'top-eu-stocks',    name: 'Top EU Stocks',        market: 'EU' },
  { slug: 'european-gems',    name: 'European Gems',        market: 'EU' },
];

// ── MARKET CLASSIFIER ─────────────────────────────────────────────────────────
function classifyMarket(slug) {
  const s = slug.toLowerCase();
  if (/sp-500|dow|tech|nasdaq|midcap|value|us-/.test(s)) return 'US';
  if (/dax|europe|eu-|european/.test(s)) return 'EU';
  if (/bist|turkey|tr-/.test(s)) return 'TR';
  return 'OTHER';
}

/**
 * discoverStrategies — scrapes ProPicks landing page for strategy links
 * Falls back to SEED_STRATEGIES if fewer than 3 found.
 *
 * @param {import('playwright').Page} page  — already authenticated Playwright page
 * @returns {Promise<Array<{ slug: string, name: string, market: string, url: string }>>}
 */
export async function discoverStrategies(page) {
  log(`Navigating to ${PROPICKS_URL}`);
  try {
    await page.goto(PROPICKS_URL, { waitUntil: 'domcontentloaded', timeout: 25_000 });
  } catch (e) {
    log(`Navigation warning: ${e.message.slice(0, 80)}`);
  }
  await page.waitForTimeout(3000);

  log('Scanning for strategy links...');

  // Extract all hrefs that match /pro/propicks/<slug>
  const discovered = await page.evaluate((base) => {
    const results = [];
    const anchors = document.querySelectorAll('a[href*="/pro/propicks/"]');
    anchors.forEach(a => {
      const href = a.getAttribute('href') || '';
      // Exclude the bare /pro/propicks page itself
      const match = href.match(/\/pro\/propicks\/([^/?#]+)/);
      if (!match) return;
      const slug = match[1];
      // Grab visible text for name
      const rawText = a.innerText?.trim() || a.textContent?.trim() || '';
      const name = rawText.replace(/\s+/g, ' ').slice(0, 80) || slug;
      const url  = href.startsWith('http') ? href : `${base}${href}`;
      results.push({ slug, name, url });
    });
    return results;
  }, BASE_URL);

  log(`Found ${discovered.length} strategy links on page`);

  // Deduplicate by slug, classify market
  const slugSeen = new Set();
  const strategies = [];

  for (const item of discovered) {
    if (slugSeen.has(item.slug)) continue;
    slugSeen.add(item.slug);
    strategies.push({
      slug:   item.slug,
      name:   item.name,
      market: classifyMarket(item.slug),
      url:    item.url,
    });
  }

  // Merge seeds if too few discovered
  if (strategies.length < 3) {
    log(`Only ${strategies.length} strategies found — merging with seed list`);
    for (const seed of SEED_STRATEGIES) {
      if (!slugSeen.has(seed.slug)) {
        slugSeen.add(seed.slug);
        strategies.push({
          slug:   seed.slug,
          name:   seed.name,
          market: seed.market,
          url:    `${BASE_URL}/pro/propicks/${seed.slug}`,
        });
      }
    }
  }

  log(`Total strategies after dedup/merge: ${strategies.length}`);
  for (const s of strategies) {
    log(`  ${s.market.padEnd(6)} ${s.slug.padEnd(30)} "${s.name}"`);
  }

  return strategies;
}
