# Host your own AI hub — a beginner copy-first guide

**Status:** Published Oct 2026. Placeholders only, no secrets.  
**What this is:** One always-on computer (a cheap VPS) that runs a private OpenAI-compatible gateway. Your scripts and bots call it over a private Tailscale network. The gateway buys answers by the token from hosted open models. Nothing sits on the public internet.

Be the best copiers on the planet. The upstream projects already exist. Wire them carefully. Keep private data off it.

---

## 0. License and terms (read before you spend a dollar)

| Piece | Upstream | License / terms you must respect |
|---|---|---|
| LiteLLM proxy | [BerriAI/litellm](https://github.com/BerriAI/litellm) · [docs](https://docs.litellm.ai/) | Root repo is **MIT** for code **outside** `enterprise/`. The `enterprise/` folder is under BerriAI’s commercial Enterprise license — **do not use enterprise features without a paid license**. Prebuilt images may include inactive enterprise code; stay on MIT surfaces. See [LICENSE](https://github.com/BerriAI/litellm/blob/main/LICENSE) and [enterprise/LICENSE.md](https://github.com/BerriAI/litellm/blob/main/enterprise/LICENSE.md). |
| OpenRouter | [openrouter.ai](https://openrouter.ai/) · [Terms](https://openrouter.ai/terms) | **Do not resell API access** or build a competing aggregator on top of it (ToS §7.4). Credits + optional Auto Recharge (§4). Review Model Terms for each model you route. |
| Docker Compose | [docs.docker.com/compose](https://docs.docker.com/compose/) | Docker Engine + Compose plugin on Ubuntu. |
| Tailscale | [tailscale.com](https://tailscale.com/) · [docs](https://tailscale.com/kb/) | Personal plan is enough to start. No Funnel for this hub. |
| DigitalOcean Droplet | [digitalocean.com/pricing/droplets](https://www.digitalocean.com/pricing/droplets) · [docs](https://docs.digitalocean.com/) | Pay for the VM + optional weekly backups + snapshots. |
| Postgres | [postgres:16-alpine](https://hub.docker.com/_/postgres) | Official image; keep it off host ports. |
| Open WebUI (optional) | [open-webui/open-webui](https://github.com/open-webui/open-webui) | Optional chat UI pointed at your LiteLLM base URL. |

This guide is not legal advice. Read the live ToS and licenses yourself before you ship.

---

## 1. What you need

1. A DigitalOcean account and a payment method.
2. An OpenRouter account with a small prepaid credit (start at $10–25).
3. A Tailscale Personal account (free) and an auth key you can rotate.
4. An SSH key pair (ed25519 is fine).
5. About 30–60 minutes for first boot once accounts exist.
6. Discipline: **non-private bulk work only** on day one (see §9).

### Rough monthly cost range (planning, not a promise)

From our own planning (public list prices, ~Oct 2026):

| Line | Light | Mid (what we ran) |
|---|---|---|
| Droplet (2 vCPU / 4 GB class) | ~$12–24 | ~$24 |
| Weekly backups + modest snapshot | ~$0–7 | ~$5–8 |
| OpenRouter tokens (bulk drafts) | ~$5–15 | ~$15–40 |
| Tailscale Personal | $0 | $0 |
| On-demand GPU | $0 (off) | $0 (off) |
| **Planning total** | **≈ $20–45 / mo** | **≈ $50–75 / mo** |

Day-one cash is mostly OpenRouter prepaid credit plus the droplet starting to accrue. Prices move — re-check vendor pages before you buy.

---

## 2. Architecture in five sentences

1. Rent one small always-on Droplet and put Docker Compose on it.
2. Join it to your Tailscale tailnet. That mesh is the front door.
3. Bind LiteLLM (and any UI) to **`<YOUR_TAILSCALE_IP>` only** — never `0.0.0.0`.
4. LiteLLM is one OpenAI-compatible endpoint (`/v1/chat/completions`) that spends tokens at OpenRouter by default.
5. Your scripts call the hub over Tailscale. The public IPv4 of the droplet stays locked down.

```
[your laptop / bots]
        |  Tailscale only
        v
[Droplet: LiteLLM :4000 + optional Open WebUI]
        |
        v
[OpenRouter → Llama 3.x class models]
```

---

## One-command install

Prefer reading the script before you run it. `curl | bash` is convenient and also a trust decision — you are giving root to whatever that URL returns today.

**Safer path (recommended):**

```bash
curl -fsSL https://raw.githubusercontent.com/poweruser702/host-your-own-ai-hub/main/install.sh -o install.sh
less install.sh
sudo env TS_AUTHKEY=<YOUR_AUTHKEY> OPENROUTER_API_KEY=<YOUR_OPENROUTER_KEY> bash install.sh
```

One-liner (only after you have read `install.sh` once):

```bash
curl -fsSL https://raw.githubusercontent.com/poweruser702/host-your-own-ai-hub/main/install.sh | sudo env TS_AUTHKEY=<YOUR_AUTHKEY> OPENROUTER_API_KEY=<YOUR_OPENROUTER_KEY> bash
```

Optional UFW apply (explicit opt-in):

```bash
sudo env TS_AUTHKEY=<YOUR_AUTHKEY> OPENROUTER_API_KEY=<YOUR_OPENROUTER_KEY> bash install.sh --lockdown
```

Preview without changing the machine:

```bash
bash install.sh --dry-run
```

What it does (automated copy of the manual path below):

1. Installs Docker Engine + Compose via Docker’s official convenience script ([get.docker.com](https://get.docker.com) / [Docker Ubuntu docs](https://docs.docker.com/engine/install/ubuntu/)).
2. Installs Tailscale via its [official install script](https://tailscale.com/download/linux), then `tailscale up` with your `TS_AUTHKEY` (no default — env or prompt).
3. Creates `/opt/ai-hub`, copies `docker-compose.yml`, and copies `litellm_config.example.yaml` → `litellm_config.yaml`.
4. Writes a mode-`600` `.env` with generated `LITELLM_MASTER_KEY`, Postgres password, and salt (values are **not** printed — only the file path is).
5. Binds LiteLLM to the Tailscale IPv4 from `tailscale ip -4` only — **never** `0.0.0.0`.
6. Prints cloud-firewall / UFW advice; applies UFW only if you pass `--lockdown`.
7. Runs a health check and one tiny test completion; prints `PASS` or `FAIL`.
8. Safe to re-run (idempotent). Supports `--dry-run`.

Uninstall (stops the stack; does not remove Docker or Tailscale):

```bash
curl -fsSL https://raw.githubusercontent.com/poweruser702/host-your-own-ai-hub/main/uninstall.sh -o uninstall.sh
less uninstall.sh
sudo bash uninstall.sh          # stop compose, keep /opt/ai-hub
sudo bash uninstall.sh --purge  # also delete /opt/ai-hub + volumes
```

Honest notes:

- **`curl | bash` risk:** the pipe skips your review. Download, `less`, then run.
- **Root:** package installs need sudo. `--dry-run` does not.
- **Secrets:** never commit `.env`. Rotate `TS_AUTHKEY` and OpenRouter keys if they leak.
- **License / ToS:** still apply — LiteLLM MIT outside `enterprise/`; OpenRouter no-resale (§7.4); read §0 above before you spend.
- **Privacy:** non-private bulk work only (see §9). This installer does not make the hub “private”.
- **Optional UI:** default install starts `db` + `litellm`. Open WebUI is a Compose profile: `docker compose --profile webui up -d` inside `/opt/ai-hub`, or pass `--with-webui` to the installer.

If you want to learn every knob, skip the installer and follow §3–§7 by hand.

---

## 3. Create the droplet

1. In DigitalOcean, create an Ubuntu 24.04 Droplet in a region near you.
2. Size that worked for our floods: **2 vCPU / 4 GB RAM** (slug class `s-2vcpu-4gb`). Smaller works for light smoke tests; floods need headroom.
3. Turn **weekly backups** on if you want the easy restore path.
4. Add your SSH public key.
5. Optional cloud-init: install Docker + Tailscale and run `tailscale up --authkey=<YOUR_AUTHKEY> --hostname=<YOUR_HUB_HOSTNAME> --ssh`.
6. Record `<YOUR_TAILSCALE_IP>` from `tailscale status` once the node joins. Use that IP everywhere below.

**Expect:** Droplet shows Active; the Tailscale machine appears on your admin console.  
**If it breaks:** Auth key rejected → mint a new tagged key. Droplet stuck → check DO status.

---

## 4. Lock the network (nothing on the public internet)

### Cloud firewall

1. During bootstrap only: allow inbound TCP 22 from **your current admin IP**.
2. After Tailscale SSH works: **empty inbound rules**. Tailscale is an overlay — you do not need public SSH or public 4000/8080.

### On the droplet (UFW)

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 to any
ufw allow OpenSSH   # keep until Tailscale SSH is proven, then you may remove
ufw --force enable
ufw status verbose
```

### Prove the lock

From a machine **not** on your tailnet:

```bash
curl --max-time 3 http://<DROPLET_PUBLIC_IP>:4000/health/liveliness
# must FAIL / time out
```

From a machine **on** your tailnet:

```bash
curl -sS http://<YOUR_TAILSCALE_IP>:4000/health/liveliness
# expect HTTP 200 and a short alive body from LiteLLM
```

---

## 5. Install Docker (if cloud-init skipped it)

```bash
docker --version
docker compose version
# If missing, follow Docker’s official Ubuntu 24.04 install, then:
systemctl enable --now docker
```

---

## 6. Deploy the compose stack

On the droplet, create an app directory (example: `/opt/ai-hub`) and copy in:

- `docker-compose.yml` (this folder — sanitized)
- `litellm_config.example.yaml` copied to `litellm_config.yaml` (compose mounts that path)
- `.env` with mode `600` (never commit)

Example `.env` **names only** (generate your own values):

```bash
HUB_BIND_IP=<YOUR_TAILSCALE_IP>
POSTGRES_PASSWORD=<long random>
LITELLM_MASTER_KEY=<long random master key>   # gate for your proxy; treat like a password
LITELLM_SALT_KEY=<long random>
OPENROUTER_API_KEY=<from openrouter.ai keys page>
WEBUI_SECRET_KEY=<long random>
```

Start:

```bash
export HUB_BIND_IP=<YOUR_TAILSCALE_IP>
docker compose up -d
docker compose ps
```

**Expect:** `db` healthy, `litellm` up, optional `open-webui` up. Port publishes show `<YOUR_TAILSCALE_IP>:4000`, not `0.0.0.0:4000`.

**If it breaks:** `docker compose logs litellm --tail 100`. Wrong bind IP → set `HUB_BIND_IP` to the live Tailscale IPv4. Missing OpenRouter key → 401/402 from upstream.

Files in this folder:

- [`install.sh`](./install.sh) — one-command installer (§ One-command install)
- [`uninstall.sh`](./uninstall.sh)
- [`docker-compose.yml`](./docker-compose.yml)
- [`litellm_config.example.yaml`](./litellm_config.example.yaml) — copied to `litellm_config.yaml` by the installer

---

## 7. First test job

Health:

```bash
curl -sS http://<YOUR_TAILSCALE_IP>:4000/health/liveliness
```

Chat completion (OpenAI-compatible):

```bash
curl -sS http://<YOUR_TAILSCALE_IP>:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bulk-small",
    "messages": [{"role": "user", "content": "Reply OK in three words."}]
  }'
```

**Expect:** A short model reply and a tiny usage block. Our live check after go-live answered in **0.43 s**.

Point scripts at:

- Base URL: `http://<YOUR_TAILSCALE_IP>:4000/v1`
- Models: `bulk-small` (cheap/fast), `bulk-70b` (heavier drafts)
- Auth: `Authorization: Bearer $LITELLM_MASTER_KEY`

Never paste the master key into chat, git, or screenshots.

---

## 8. Spend caps and the “never turn on auto-recharge” tip

OpenRouter bills prepaid credits. Auto Recharge is optional in their dashboard ([Terms §4.2](https://openrouter.ai/terms)).

**Hard rules we run with:**

1. Set a **personal hard stop** you will honor (example policy: stop new bulk when cumulative usage hits a number you chose — we use a standing policy ceiling and a tighter prepaid buffer).
2. Prefer **prepaid credit + manual top-ups** you approve yourself.
3. **Never turn on Auto Recharge from automation.** If a bot or script can buy credit, it will eventually buy credit at 2 AM. Keep Auto Recharge **OFF** unless you personally enable it and know the threshold.
4. Put a billing alert on the droplet host (example: DigitalOcean billing alert around your infra envelope — we plan ~$30–40/mo infra).
5. Optional: LiteLLM virtual keys with per-key budgets once Postgres is healthy (see LiteLLM key docs). Sum of key budgets should not exceed the credit you actually prepaid.

Tonight-scale proof (measured on our box, non-private smoke/flood jobs only):

| Proof | Result |
|---|---|
| Flood at 64 concurrent | **1000/1000** jobs, **0%** failures |
| Peak throughput | **571.7** jobs/min |
| OpenRouter spend for that spike | about **$0.18** total |
| Live check | answered in **0.43 s** |
| RAM on a small 4 GB droplet | about **65%** |

Earlier ramps on the same night: peak **358.2** jobs/min at concurrency 32, then **502.3** jobs/min at 64 on an 800-job wave — all 0% fail before the 1000-job run.

---

## 9. Keep private data off it

This hub is for **non-private bulk work**: generic drafts, public docs, redacted design notes, stress tests.

Do **not** send:

- Health / medical content
- Kids or family private details
- Client confidential files
- Credentials, API keys, wallet seeds
- Money ledgers or full account numbers
- Anything you would not paste into a random SaaS

Why: OpenRouter and model providers have their own logging/training settings and Model Terms. Even with careful account toggles, treat the hub as **Tier A / public-ish** until you have a real privacy review, BAAs where needed, and a separate private path.

Practical gate before every job:

1. Is this already redacted / public?
2. If unsure → keep it off the hub.
3. Turn off provider training toggles you do not want; still assume bulk drafts are non-private.

---

## 10. Optional next copies (after the hub is boring)

- Snapshot the droplet the day it first works (restore beats rebuild).
- Add Open WebUI only if you want a browser chat pointed at LiteLLM.
- Skip always-on GPU rental until a job truly needs it.
- Do not white-label n8n / Open WebUI for clients on this same box without a fresh license and ToS pass.
- Do not resell OpenRouter access.

---

## 11. Upstream links (bookmark these)

- LiteLLM GitHub: https://github.com/BerriAI/litellm
- LiteLLM proxy config docs: https://docs.litellm.ai/docs/proxy/configs
- OpenRouter models: https://openrouter.ai/models
- OpenRouter terms: https://openrouter.ai/terms
- Tailscale docs: https://tailscale.com/kb/
- DigitalOcean Droplets: https://docs.digitalocean.com/products/droplets/
- Docker Compose: https://docs.docker.com/compose/
- Official LiteLLM + Postgres compose pattern: see BerriAI’s repo `docker-compose.yml`

---

## 12. Copy checklist

- [ ] Droplet up, Tailscale joined, `<YOUR_TAILSCALE_IP>` recorded
- [ ] Cloud firewall empty inbound (after Tailscale SSH works)
- [ ] UFW denies public inbound; allows `tailscale0`
- [ ] `.env` mode 600; no secrets in git
- [ ] `docker compose up -d` — LiteLLM healthy on Tailscale only
- [ ] Health check 200 over Tailscale; public `:4000` fails
- [ ] First chat completion returns OK
- [ ] OpenRouter Auto Recharge **OFF**
- [ ] Personal spend hard stop written down
- [ ] Privacy gate: non-private jobs only

That’s the whole move: rent a small box, put a MIT LiteLLM proxy on it, lock it to Tailscale, spend pennies on open models, and keep your private life elsewhere.
