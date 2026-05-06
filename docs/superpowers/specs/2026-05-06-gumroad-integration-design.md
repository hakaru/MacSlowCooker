# Gumroad Integration Design

Date: 2026-05-06

## Overview

Two-part integration: a standalone Python server (`gumroad-manager`) handles GitHub release
automation and sales analytics; MacSlowCooker itself gains a license key verification UI.

### Goals

- **A+B**: Auto-update Gumroad product (file, description, cover image) on every GitHub release
- **C**: Collect daily sales data and display in a personal dashboard
- **D**: License key input + verification in MacSlowCooker Preferences

### Out of Scope (v1)

- Buyer update notification emails
- External CDN distribution
- Forced license gating (verification is optional in v1)

---

## Architecture

```
GitHub Release (tag push)
    ↓ webhook POST /webhook/github/{product_name}
gumroad-manager (FastAPI, Python, Render.com)
    ├── webhook.py      HMAC-SHA256 verify → BackgroundTask
    │   ├── Download release asset (.dmg / .zip) from GitHub
    │   ├── PATCH /v2/products/{id}   — description + version
    │   ├── PUT   /v2/products/{id}/files — file replacement
    │   └── PUT   /v2/products/{id}/cover  — cover image (if present)
    ├── scheduler.py    APScheduler daily cron
    │   └── GET /v2/sales → aggregate → SQLite
    └── dashboard.py    GET /dashboard → HTML

MacSlowCooker.app (Swift)
    └── Preferences — License section
        ├── LicenseValidator.swift  POST /v2/licenses/verify
        └── Settings.swift          licenseKey + licenseVerifiedAt (UserDefaults)
```

---

## Repository Layout

| Repository | Contents |
|---|---|
| `gumroad-manager` (new, standalone) | FastAPI server — A + B + C, multi-product |
| `MacSlowCooker` (existing) | License verification — D only |

### `gumroad-manager` directory structure

```
gumroad-manager/
├── app/
│   ├── main.py           # FastAPI entry point, product config loading
│   ├── webhook.py        # GitHub webhook handler
│   ├── gumroad.py        # Gumroad API client (httpx)
│   ├── scheduler.py      # APScheduler daily sales fetch
│   ├── dashboard.py      # GET /dashboard HTML route
│   └── database.py       # SQLite (aiosqlite)
├── config.yaml           # Per-product settings
├── requirements.txt
└── Dockerfile
```

---

## Multi-Product Configuration

```yaml
# config.yaml
products:
  - name: MacSlowCooker
    gumroad_product_id: fzifrw
    github_repo: hakaru-inc/MacSlowCooker
    webhook_secret: ${MSC_WEBHOOK_SECRET}
  - name: NextApp
    gumroad_product_id: xxxxx
    github_repo: hakaru-inc/NextApp
    webhook_secret: ${NEXTAPP_WEBHOOK_SECRET}
```

Environment variables: `GUMROAD_ACCESS_TOKEN`, `MSC_WEBHOOK_SECRET`, etc.

---

## Data Model (SQLite)

```sql
CREATE TABLE daily_sales (
    date        TEXT PRIMARY KEY,  -- "2026-05-06"
    product     TEXT NOT NULL,     -- "MacSlowCooker"
    revenue     REAL,              -- USD
    unit_count  INTEGER,
    fetched_at  TEXT               -- ISO8601
);

CREATE TABLE sales_summary (
    product    TEXT,
    key        TEXT,               -- "total_revenue", "total_units"
    value      TEXT,
    updated_at TEXT,
    PRIMARY KEY (product, key)
);
```

No buyer PII stored. Gumroad dashboard is the source of truth for transactions.

---

## Release Webhook Flow (A+B)

1. GitHub fires `release.published` event
2. Server responds `202 Accepted` immediately
3. Background task runs:
   - Verify HMAC-SHA256 signature
   - Fetch `.dmg` / `.zip` asset URLs from release payload
   - Stream-download files from GitHub (Authorization header required for private repos)
   - `PATCH /v2/products/{id}` — update description with release notes + version tag
   - `PUT /v2/products/{id}/files` — replace download file
   - If cover image URL found in release body → `PUT /v2/products/{id}/cover`
4. Errors logged; no automatic retry (manual re-trigger via re-publishing release)

---

## Sales Data Collection (C)

- APScheduler fires daily at 00:00 UTC
- Calls `GET /v2/sales?product_id={id}&after={yesterday}`
- Aggregates revenue + unit count → upserts `daily_sales`
- `GET /dashboard` renders totals + 30-day bar chart (plain HTML, no JS framework)

---

## License Verification in MacSlowCooker (D)

**New files:**
- `MacSlowCooker/LicenseValidator.swift` — pure async function, calls Gumroad API, testable

**Modified files:**
- `MacSlowCooker/Settings.swift` — add `licenseKey: String`, `licenseVerifiedAt: Date?`
- `MacSlowCooker/PreferencesWindowController.swift` — add License section to SwiftUI Form

**Verification flow:**
```
User enters key → tap "Verify"
    POST https://api.gumroad.com/v2/licenses/verify
    { product_permalink: "fzifrw", license_key: "XXXX" }
    200 success → save key + timestamp to UserDefaults
    failure     → show error message inline
```

On next launch: cached UserDefaults value used (offline-tolerant).
Verification is **optional** — all features available without a valid license in v1.

---

## Deployment

- **Platform**: Render.com free tier (spins down after inactivity — acceptable for webhook + daily cron)
- **Secrets**: Render environment variables (never in config.yaml or source)
- **GitHub webhook**: Set in each repo's Settings → Webhooks, URL: `https://{render-host}/webhook/github/{product_name}`
