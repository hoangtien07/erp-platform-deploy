# INFRA_EVAL — minimum-cost infra cho Alpha 1–5 users

**Status:** RESEARCH + feasibility (no live deployment). Verified against
official docs 2026-10-09; claims not firsthand-tested are labeled
`[vendor claim]` / `[suy luận]` / `[community report]`.

**Founder directive (2026-10-09):** Cloudflare Free Tunnel + Access → existing
Docker host → EWCP Product + Kernel + ERPNext G1′. Không mua Workers Paid /
VPS / GPU cho tới khi có requirement đo được. Evaluate Oracle Always Free
ARM64 làm alternative host; không migrate mù. Workers AI Free/PAYG cho
non-sensitive workloads; Ollama local cho local-only. KHÔNG migrate
ERPNext/DeerFlow/Next.js sang Workers chỉ để né VPS cost.

---

## TL;DR

1. **Cloudflare Free Tunnel + Access đủ cho 1–5 users** — tunnel không giới
   hạn bandwidth, Access free 50 users, OTP email zero-config. Recommended
   first move đúng như founder chỉ đạo. Cost = $0 + một domain trên
   Cloudflare Free zone (yêu cầu duy nhất).
2. **Một rủi ro kỹ thuật thật cần đo trong PoC: SSE-over-GET.** Frontend
   EWCP `joinRunStream` dùng GET SSE; Cloudflare edge có report buffer GET
   SSE (POST SSE stream bình thường). PoC phải đo event latency end-to-end
   trước khi declare success. Mitigation đã spec sẵn (POST / WS / header).
3. **Oracle Always Free ≠ như headline cũ.** Free tenancy hiện tại =
   **2 OCPU + 12 GB** A1.Flex (không phải 4 OCPU/24 GB), "out of capacity"
   kéo dài nhiều tháng là báo cáo phổ biến, và idle <20%/7 ngày bị reclaim.
   Toàn stack có arm64 image (verify manifest trực tiếp) nên kỹ thuật chạy
   được — nhưng chỉ nên dùng như fallback host, không migrate chủ động.
4. **Workers AI free = dev-scale quota.** 10k neurons/day; model
   tool-calling dùng được trên free tier: `llama-3.3-70b-instruct-fp8-fast`
   (function calling: Yes, qua OpenAI-compat REST). Frontier models
   (Kimi K2.6/K2.7, GLM-5.x, DeepSeek v4) đều "Paid access required".
5. **Residency note (trung thực):** payload được giải mã tại Cloudflare
   edge — "data stays on-prem" chỉ đúng với data-at-rest. Regional
   Services (chọn vùng decrypt) là add-on Enterprise.

---

## 1. Cloudflare Free Tunnel + Access — verify

| Claim | Verdict | Evidence |
|---|---|---|
| cloudflared tunnel free | **Đúng.** Available on all plans; 1,000 tunnels + 1,000 hostname/CIDR routes per account, 25 active replicas/tunnel, no bandwidth cap (community-staff answer: "no bandwidth limits"). | [account-limits](https://developers.cloudflare.com/cloudflare-one/account-limits/), [community](https://community.cloudflare.com/t/cloudflare-tunnel-limits-and-bandwith/393006) |
| Access free 50 users | **Đúng.** Free plan $0 forever, ≤50 users. Vượt 50 phải upgrade Zero Trust plan — sau upgrade **mọi seat đều bill** (~$7/user/mo), không có "50 free + N paid". | [plans](https://www.cloudflare.com/plans/), [community billing](https://community.cloudflare.com/t/not-sure-how-to-upgrade-from-free-zero-trust-plan-to-standard/618213) |
| Auth method: email OTP / IdP | **Đúng.** One-time PIN tới email whitelist "no configuration needed"; IdP: Google/GitHub/social + generic OIDC/SAML. | [idp-integration](https://developers.cloudflare.com/cloudflare-one/identity/idp-integration/) |
| WebSocket qua tunnel | **Đúng.** "Cloudflare supports proxied WebSocket connections without additional configuration" (Network → WebSockets On). Frappe socket.io chạy qua được — case lỗi phổ biến là WAF country block, không phải tunnel. | [websockets](https://developers.cloudflare.com/network/websockets/), [frappe forum](https://discuss.frappe.io/t/how-to-enable-socket-io-with-cloudflare-proxy-enabled-for-erpnext-frappe/140396) |
| SSE qua tunnel | **Rủi ro thật.** POST-SSE stream realtime; **GET-SSE bị buffer** tới khi connection đóng trên Quick Tunnel (issue #1449, 2025) và report tương tự trên proxy nói chung (#1496, #199). `[suy luận]` named tunnel + cấu hình origin đúng (`X-Accel-Buffering: no`, chunked) có thể vẫn ổn — phải đo trong PoC. | [#1449](https://github.com/cloudflare/cloudflared/issues/1449), [#1496](https://github.com/cloudflare/cloudflared/issues/1496), [#199](https://github.com/cloudflare/cloudflared/issues/199) |
| TLS termination | Client→edge TLS decrypt tại **mọi DC toàn cầu** (default). edge→cloudflared = encrypted QUIC tunnel (outbound-only từ origin, port 7844, không cần mở inbound firewall). Cloudflare là middle-party nhìn thấy plaintext L7 — điều kiện để Access/WAF hoạt động. Regional Services (giới hạn vùng decrypt) = **Enterprise add-on**, không có trên Free. | [DLS](https://developers.cloudflare.com/data-localization/), [http-requests](https://developers.cloudflare.com/data-localization/regional-services/http-requests/), [tunnel terms](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/tunnel-useful-terms/) |
| Machine-to-machine qua Access | Service Token (`CF-Access-Client-Id`/`CF-Access-Client-Secret`) — free, cùng policy engine. | [service-tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/) |
| Domain requirement | Published app route cần **domain đã add vào Cloudflare zone** (Free DNS plan đủ). Multi-level subdomain cần Advanced Certificate (paid) → dùng single-level subdomain. | [create-remote-tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-remote-tunnel/) |

**Residency honesty cho "data stays on-prem" thesis:** data-at-rest (DB,
files, sqlite kernel) ở lại on-prem đúng. In-transit: user→edge và
edge→origin đều mã hóa, nhưng Cloudflare edge decrypt để enforce L7 policy —
Cloudflare là trusted third party trong đường đi của plaintext. Metadata
(request logs, Access logs) nằm ở Cloudflare. Nếu alpha users chấp nhận
điều này (hầu hết SME sẽ chấp nhận — giống mọi SaaS đặt sau CDN), kiến
trúc vẫn hợp lệ; chỉ không được *claim* "data never leaves our infra".

## 2. Stack fit — một tunnel, nhiều hostname

Services thật trên Docker host (verify từ repo + AGENTS.md):

| Service | Port hiện tại | Cần public hostname? | Route |
|---|---|---|---|
| Product nginx (DeerFlow, prod `make up`) | `127.0.0.1:2026` | **Có** — browser entry duy nhất (frontend + `/api/*` → gateway 8001, SSE/api internally) | `app.<domain>` → `http://localhost:2026` |
| ERPNext G1′ frontend nginx | `127.0.0.1:8080` (**trùng kernel — phải remap**, `HTTP_PORT=8081`) | **Có** — Desk UI + REST/token API cho alpha ops | `erp.<domain>` → `http://localhost:8081` |
| EWCP kernel (uvicorn) | `127.0.0.1:8080` | **Không.** Gateway gọi kernel in-network; không expose ra tunnel — giảm attack surface. | — (internal only) |
| Kernel→ERPNext, ERP→DB/Redis | docker network | Không | — (internal only) |

Caveats cụ thể cần xử lý trong PoC:

- **Port collision:** `docker-compose.yml` mặc định `HTTP_PORT=8080` đụng
  kernel 8080. Đặt `HTTP_PORT=8081` trong `.env` (one-line change, không
  sửa compose).
- **Frappe site resolution:** smoke test đã verify
  `FRAPPE_SITE_NAME_HEADER=${SITE_NAME}` khiến nginx pin site cho mọi Host
  (`docs/G1_LOCAL_SMOKE.md`). Tuy nhiên convention của frappe_docker là
  **site dir name == public hostname**; một user report fix websocket bằng
  cách đặt `FRAPPE_SITE_NAME_HEADER` = full domain
  ([frappe_docker#1456](https://github.com/frappe/frappe_docker/issues/1456)).
  → PoC spec đặt `SITE_NAME=erp.<domain>` (tên site = hostname public),
  tránh cả class lỗi host-mismatch.
- **CSRF/Origin trên POST:** `[suy luận]` Frappe Desk POSTs qua session
  cookie dùng frappe CSRF token — host-mismatch có thể gây lỗi trên một số
  version; REST token auth (kernel→ERP) không đi qua browser Origin nên
  không ảnh hưởng. Đặt site = hostname khử gốc vấn đề. Verify trong PoC
  bằng 1 Desk POST thật.
- **Next.js:** prod build không cần cấu hình thêm. Dev-mode mới cần
  `DEER_FLOW_DEV_ALLOWED_ORIGINS` (frontend AGENTS.md) — không dùng dev
  qua tunnel.
- **Access cho API paths:** ERPNext REST dùng `Authorization: token k:s`
  (không phải browser session). Hai lựa chọn: (a) Access Service Token cho
  caller, hoặc (b) Access policy `bypass` cho path `/api/*` trên
  `erp.<domain>` — kernel→ERP đi internal nên (a) chỉ cần cho external
  tooling, không cần cho kernel.

## 3. Oracle Always Free ARM64 — verify + correction

**Correction quan trọng:** headline "4 OCPU + 24 GB" đã **lỗi thời**.
Doc hiện hành ghi: 1,500 OCPU-hours + 9,000 GB-hours/tháng free, và nói
rõ "for Always Free tenancies, this is equivalent to **2 OCPUs and 12 GB**
of memory" — max 2 instance A1.Flex. (1,500/730h ≈ 2.05 OCPU chạy liên
tục.) Nâng cấp lên PAYG mới mở shape lớn hơn trong cùng quota.
[Oracle Always Free docs](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)

Thông số khác (cùng doc): 200 GB block volume tổng, 2× AMD
VM.Standard.E2.1.Micro (1 GB RAM — quá nhỏ cho stack này), **10 TB/tháng
outbound data** free — rất hào phóng so với AWS/GCP free tier.

Catches (nghiêm túc):

- **"Out of host capacity"** — Oracle tự ghi trong doc; community report
  hàng tháng trời không provision được ở region phổ biến; tồn tại cả
  tool riêng để retry (`oci-arm-host-capacity`,
  [oracle-cloud-repeater](https://github.com/sam-bee/oracle-cloud-repeater),
  [SO thread](https://stackoverflow.com/questions/78821885/),
  [Oracle community](https://community.oracle.com/customerconnect/discussion/905776/)).
  `[suy luận]` không nên plan primary host dựa trên tài nguyên không chắc
  provision được.
- **Idle reclamation:** <20% CPU/network/memory ở p95 trong 7 ngày → bị
  reclaim. Host alpha ít traffic vẫn có baseline activity, nhưng VM phụ
  hay tắt sẽ mất.
- **Capacity trên free tenancy có thể bị thu hẹp theo thời gian** (đã giảm
  4→2 OCPU một lần).

**ARM64 compatibility — verified trực tiếp** (`docker manifest inspect`,
2026-10-09):

| Image | arm64 manifest? |
|---|---|
| `frappe/erpnext:v16.50.0` | ✅ amd64 + arm64 |
| `mariadb:11.8`, `redis:7-alpine`, `nginx:alpine` | ✅ |
| `python:3.14-slim`, `node:24-alpine` | ✅ |
| `cloudflare/cloudflared` | ✅ |
| `enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:1.11.0` | ✅ (bất ngờ — registry Volces cũng multi-arch) |

Caveats còn lại: image self-build (product frontend/gateway) phải build
multi-arch; native pip wheels của ERPNext trên arm64 `[suy luận]` ổn
(mariaDB/redis driver, pandas/lxml đều có aarch64 wheel) nhưng Playwright/
Chromium trong aio-sandbox trên arm64 là điểm hay gãy — chưa verify.

**Verdict Oracle:** kỹ thuật khả thi (manifest verified), chiến lược KHÔNG
khả thi làm primary: 2 OCPU/12 GB chạy được stack cho 1–5 users nhưng
provision không chắc + idle-reclaim + headroom mỏng cho MariaDB+Redis+
queues+kernel+Next trong 12 GB (working set ước ~6–9 GB `[suy luận]`).
Giữ làm **fallback/DR host** hoặc runner phụ — provision được lúc nào
dùng lúc đó, không migrate chủ động.

## 4. Cloudflare Workers AI — free tier verify

| Claim | Verdict | Evidence |
|---|---|---|
| Free quota | **10,000 Neurons/day/account**, tổng cộng (không phải per-model). Vượt quota cần Workers Paid ($5/mo), $0.011/1k neurons sau quota. | [pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| Tool-calling model trên free | **`@cf/meta/llama-3.3-70b-instruct-fp8-fast`**: Function calling = Yes, 24k ctx, $0.293/M-in $2.253/M-out (converted). Không có nhãn "Paid access required". | [model page](https://developers.cloudflare.com/workers-ai/models/llama-3.3-70b-instruct-fp8-fast/) |
| Frontier models | `kimi-k2.6` (và tương tự glm-5.x, deepseek-v4): **"Paid access required — not available through standard Workers Free billing"** (Workers Paid hoặc prepaid AI Gateway credits). | [kimi-k2.6](https://developers.cloudflare.com/workers-ai/models/kimi-k2.6/) |
| Access pattern | REST endpoint `api.cloudflare.com/.../ai/run/<model>` + **OpenAI-compatible endpoint** — gateway gọi được như một OpenAI backend; `tool_calls` truyền thống qua REST OK. "Embedded function calling" (runWithTools) chỉ có trong Workers runtime, không qua REST. | [function-calling](https://developers.cloudflare.com/workers-ai/features/function-calling/), [open-ai-compatibility](https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility/) |
| Quota ý nghĩa thực tế | `[suy luận]` 10k neurons/day ≈ vài trăm request nhẹ/ngày trên 70B — đủ cho non-sensitive triage/classify/extract ở alpha scale, không đủ cho agent-loop nặng. Streaming SSE có hỗ trợ (`stream:true`). |

**Fit cho gateway:** non-sensitive workloads (intent classify, label,
summary của data không nhạy) có thể route `llama-3.3-70b-instruct-fp8-fast`
qua OpenAI-compat endpoint = một `ChatOpenAI` config trong
`config.yaml` — zero new infra. Sensitive/governed lanes giữ Gemini key
hiện tại hoặc Ollama local. Không có tool-calling model free nào tốt hơn
llama-3.3-70b hiện tại.

## 5. Decision matrix

| Option | Cost/mo | Latency (VN users) | Residency | Effort | Verdict |
|---|---|---|---|---|---|
| **A. Existing Docker host + CF Tunnel + Access** | $0 + domain (~$0–15/yr nếu chưa có) | +10–40 ms qua CF PoP gần nhất `[vendor claim]` CF có PoP VN — đo trong PoC | Data-at-rest on-prem; L7 plaintext tại CF edge; metadata ở CF | Thấp: 1 compose service + dashboard config | **Do first** |
| **B. Oracle A1 2 OCPU/12 GB + tunnel** | $0 | Tùy region (SG/JP gần nhất ~40–80 ms) `[suy luận]` | Data-at-rest ở Oracle region — rời on-prem | Trung: ARM64 OK nhưng provision không chắc | Fallback/DR only |
| **C. Paid VPS + tunnel** | ~$5–10 | Tùy DC | Tùy provider | Thấp | Khi A chết/đầy capacity — có trigger đo được mới mua |
| **D. Workers AI non-sensitive** | $0 trong 10k neurons/day | edge call ~nhanh | Prompt+response qua CF — chỉ non-sensitive | Rất thấp: 1 provider config | Pilot song song, không block |
| **E. Ollama local** | $0 (điện host) | local | Hoàn toàn on-prem | Trung: model pull + routing | Cho workloads nhạy cảm đã định nghĩa |
| F. Migrate app sang Workers/Pages | $0–5 | thấp | Toàn bộ trên CF | **Cao, sai directive** | **Reject** — founder đã cấm migrate để né VPS |

## 6. Recommended order + upgrade triggers

1. **PoC tunnel (spec §7)** — $0, ~1 buổi setup + đo SSE. Gate duy nhất:
   founder có domain add được vào Cloudflare Free zone.
2. **Access OTP cho 1–5 emails** — trong cùng PoC.
3. **Workers AI pilot** — thêm provider `llama-3.3-70b-instruct-fp8-fast`
   cho non-sensitive lane khi nào có workload cụ thể (không làm trước
   spec).
4. **Oracle ARM** — chỉ provision khi: (a) host hiện tại fail/đầy, hoặc
   (b) cần DR host. Retry provision nền; không block roadmap.
5. **Trả tiền khi đo được:** >50 Access users → Zero Trust Standard;
   host RAM/CPU saturates (đo bằng `docker stats` + kernel metrics) → VPS
   hoặc Oracle; Workers AI quota chạm trần với workload thật → Workers
   Paid $5; SSE fix không khả thi → WS fallback hoặc direct-IP
   tailnet (Tailscale free cũng là plan B cho private access).

Measurement cần log ngay từ PoC (để trigger có số liệu):
end-to-end latency của `joinRunStream` event đầu tiên qua tunnel vs direct;
RAM/CPU trên docker host (`docker stats` snapshot hàng tuần); Access login
success rate; Workers AI neurons/day thực dùng nếu pilot.

## 7. PoC spec — cloudflared + Access (READY, chưa thực thi)

Gate: **1 domain** thêm vào Cloudflare Free zone (founder cung cấp) + Cloudflare
account free + quyền dashboard Zero Trust.

### 7a. Compose service (thêm vào `docker-compose.yml` của deploy stack)

```yaml
  cloudflared:
    image: cloudflare/cloudflared:2025.9.0   # pin version khi implement
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN:?set in .env — lấy từ
        dashboard Networking > Tunnels > <tunnel> > Install}
```

Remotely-managed tunnel (token) thay vì local config file → config nằm
trong dashboard, không cần cert.json trong repo. Token là secret → `.env`
(gitignored), không commit.

### 7b. Published application routes (dashboard, per tunnel)

| Hostname | Service URL | Ghi chú |
|---|---|---|
| `app.<domain>` | `http://localhost:2026` | product nginx (prod stack) |
| `erp.<domain>` | `http://localhost:8081` | ERPNext frontend — requires `HTTP_PORT=8081` trong `.env` để tránh kernel :8080 |

Không publish kernel :8080. cloudflared trỏ `localhost` khi chạy cùng host
network; nếu chạy trong compose network thì service URL là
`http://frontend:8080` / `http://<product-nginx>:2026` — quyết định lúc
implement theo compose thật của host.

### 7c. Access applications (Zero Trust > Access > Applications)

- `app.<domain>`: Self-hosted app; policy `allow` — `emails: [u1..u5]`;
  login methods: One-time PIN (zero-config) + optional Google IdP.
- `erp.<domain>`: Self-hosted app; cùng policy; **không** bypass `/api/*`
  ở PoC (kernel→ERP đi internal; external API caller sau này dùng
  Service Token).
- Session duration: default; evaluate "App Launcher" cho 2 app gộp 1 cửa.

### 7d. App-side changes

- `erp-platform-deploy/.env`: `HTTP_PORT=8081`, `SITE_NAME=erp.<domain>`
  → site name = public hostname (xóa site cũ hoặc `bench rename-site`
  nếu muốn giữ fixtures — G1′ là throwaway nên recreate nhanh hơn).
- Product: prod `make up` (không dev). Không cần code change trước mắt.
- Kernel: không đổi.

### 7e. Verification checklist (định nghĩa "PoC pass")

1. `https://app.<domain>` mở được sau OTP login; thread chat + run mới
   stream realtime (đo event-first-byte qua tunnel so với localhost:2026
   direct — target <500 ms chênh).
2. **`joinRunStream` GET-SSE:** 1 run ≥30 s — nếu events chỉ đến sau khi
   stream đóng → bị buffer → mitigation theo thứ tự: (a) origin nginx
   thêm `X-Accel-Buffering: no` + `proxy_buffering off` cho route stream;
   (b) đổi join endpoint sang POST (theo #1449 POST stream OK); (c) WS
   fallback. Ghi kết quả vào doc này.
3. `https://erp.<domain>` Desk login + 1 POST thật (create draft PO qua
   ewcp_bridge) + socketio connected (`frappe.realtime.socket.connected`).
4. Token API `erp.<domain>/api/resource/*` từ external caller qua Service
   Token.
5. `docker stats` snapshot + ghi baseline RAM/CPU vào doc.

### 7f. Out of scope cho PoC

Không enable: WAF rules custom, Argo (mất websocket-compat), Workers
routes, Load Balancing, multi-level subdomain (cần Advanced Cert paid),
ERPNext migrate, bất kỳ purchase nào.

---

## Evidence quality

- **Firsthand-verified ở session này:** arm64 manifests của toàn bộ images
  (`docker manifest inspect`); service/ports từ repo compose + AGENTS.md;
  `joinRunStream` là GET SSE (api.ts:416 product/vnext).
- **Official docs:** tất cả URL trong bảng.
- **[community report]:** Oracle capacity, SSE buffering issues.
- **[suy luận]:** latency PoP VN, CSRF edge-case, RAM estimate, neurons/day
  throughput.
- **Chưa verify:** hành vi SSE qua *named* tunnel (chỉ có report trên
  Quick/proxy chung) → là mục đo bắt buộc của PoC; aio-sandbox trên arm64
  thực tế boot hay không.
