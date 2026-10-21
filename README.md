# deploy-ocr

Deploy NILAM OCR ke GKE dari image yang sudah ada di Nexus BRI. Repo ini **tidak membangun image**;
image di-push dari repo aplikasinya (`nilam-ocr-orchestration/deploy/push-nexus.sh`) ke
`new-nexus.gcp.bri.co.id/bribrain/<dev|prd>/nilam/<project>/<image>:<git-sha>`.

**Panduan langkah deployment:** [docs/deployment.docx](docs/deployment.docx).

| Komponen | Chart | Script | Image Nexus |
|---|---|---|---|
| OCR backend: api + worker (satu image) | `charts/ocr-backend` | `./deploy.sh ocr-backend` | `ms-bribrain-nilam-ocr-orchestrator` |
| RBAC admin UI | `charts/ocr-rbac-ui` | `./deploy.sh rbac-ui` | `mf-bribrain-nilam-ocr-admin-ui` |
| Redis bersama untuk banyak team (env `shared`) | `charts/redis` | `./deploy.sh redis`, `scripts/services/redis/user.sh` | `redis` (salinan Docker Hub) |
| NILAM OCR akta: 5 service, satu release per service | `charts/ocr-akta` | `./deploy.sh ocr-akta-<service>`, `./deploy.sh akta` | `ms-bribrain-nilam-ocr-akta-<service>` (folder Nexus sendiri) |

## Struktur

```
charts/<chart>/            chart generik, tanpa nilai khusus environment
environments/<env>.env     target GKE + path Nexus + nama release (tidak di-commit; salin dari <env>.env.example)
environments/<env>/*.yaml  override values per chart untuk environment itu
scripts/services/<service>/  script per service: deploy, operasi, dan probe
scripts/                     helper bersama `_lib.sh` dan `kube.sh`
deploy.sh                    entrypoint; bisa deploy backend lalu UI lewat `application`, kelima service akta lewat `akta`
scripts/services/ocr-backend/create-superadmin.sh  buat akun superadmin shared lewat nano
.env                         rahasia lokal (akun Nexus), tidak di-commit
```

Urutan prioritas nilai: **env shell > `.env` > `environments/<env>.env`**. Values helm: `charts/<chart>/values.yaml`
→ `environments/<env>/<chart>.yaml` → `--set` dari script → argumen setelah `--`.

## Prasyarat

- `gcloud` (sudah `gcloud auth login`), `gke-gcloud-auth-plugin`, `kubectl`, `helm` 3.13+ atau 4, `docker`
- `docker login new-nexus.gcp.bri.co.id` di mesin ini, dan VPN kantor aktif (script mengecek tag ada di Nexus
  sebelum deploy)
- Cluster bisa menjangkau `new-nexus.gcp.bri.co.id` dan punya metrics-server (untuk HPA)
- Cluster private (env `shared`): akses SSH lewat IAP ke bastion-nya (OS Login), cek dengan
  `gcloud compute ssh <bastion> --tunnel-through-iap --zone <zona> --project <project>`

## Sekali di awal

```bash
cp .env.example .env    # isi NEXUS_USERNAME / NEXUS_PASSWORD (akun service, bukan akun pribadi)
cp environments/dev.env.example environments/dev.env        # isi project, cluster, host Nexus
cp environments/shared.env.example environments/shared.env  # plus bastion
```

`.env` dan `environments/<env>.env` di-ignore git; nilainya minta ke tim infra atau rekan yang sudah punya.

Script membuat/memperbarui Secret pull `nexus-pull-secret` dari akun itu setiap deploy.

**Secret aplikasi** `ocr-orchestration` (dibaca api dan worker lewat `envFrom`) dibuat manual, tidak lewat chart,
supaya rahasia tidak pernah masuk values. Isinya `.env` aplikasi dengan alamat versi cluster; resep lengkapnya di
`nilam-ocr-orchestration/deploy/README.md` bagian "Install pertama kali":

```bash
kubectl create secret generic ocr-orchestration -n <namespace> --from-env-file=/tmp/ocr.env
./scripts/kube.sh --env shared -- kubectl create secret generic ocr-orchestration \
  -n nilam-ocr-orchestrator --from-env-file=/tmp/ocr.env                 # cluster private
```

Untuk konfigurasi Bedrock aplikasi, tambahkan tiga variabel ini ke file `/tmp/ocr.env`:

- `AWS_BEARER_TOKEN_BEDROCK` — Bedrock API key; rahasia, dan tidak memerlukan `AWS_ACCESS_KEY_ID` atau `AWS_SECRET_ACCESS_KEY`.
- `AWS_REGION_NAME` — region AWS, misalnya `ap-southeast-3`.
- `BEDROCK_MODEL_ID` — ID model yang dipakai aplikasi.

Chart meneruskan isi Secret `ocr-orchestration` ke container API dan worker tanpa memerlukan perubahan values. Pastikan image aplikasi membaca nama variabel tersebut. Secret `bedrock-probe-credentials` di bagian probe di bawah terpisah dan hanya dipakai oleh skrip tes konektivitas.

URL di Secret itu (`REDIS_URL`, `OCR_<TYPE>_SERVICE_URL`, `DATAHUB_SERVICE_URL`) pakai FQDN
`<service>.<namespace>.svc.cluster.local` bila servisnya ada di namespace lain.

## Deploy

```bash
./deploy.sh ocr-backend ec05d54                 # api + worker, env dev
./deploy.sh rbac-ui d25f1de                     # admin UI, env dev
./deploy.sh application ec05d54 d25f1de --env shared  # backend dulu, lalu UI
./deploy.sh redis 7.4.7-alpine --env shared    # Redis bersama
```

Deploy backend dulu: nginx admin UI meneruskan `/api` ke Service backend.

Bedrock probe hanya untuk `shared`; Service-nya internal (`ClusterIP`) dan tidak membuka endpoint publik.

Probe pod menetapkan request CPU `100m`/memory `128Mi` dan limit CPU `400m`/memory `384Mi`, agar memenuhi batas rasio resource cluster shared.

Secret `bedrock-probe-credentials` tidak dibuat otomatis. Siapkan file lokal yang tidak di-commit dengan
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, dan `AWS_SESSION_TOKEN` bila memakai kredensial sementara;
sertakan `AWS_REGION` bila region tidak diberikan ke script tes. Kredensial perlu izin
`bedrock:ListFoundationModels`. Buat atau perbarui Secret tanpa menaruh nilainya di argumen shell:

```bash
AWS_CREDENTIALS_FILE=/path/aman/bedrock-credentials.env \
./scripts/kube.sh --env shared -- bash -ceu '
  kubectl create secret generic bedrock-probe-credentials \
    -n "$BEDROCK_NAMESPACE" \
    --from-env-file="$AWS_CREDENTIALS_FILE" \
    --dry-run=client -o yaml |
  kubectl apply -f -
'
./scripts/services/bedrock/test-connectivity.sh --env shared --region <aws-region>
```


Tag wajib dan harus git short sha yang sudah di-push; tidak ada tag default seperti `dev`/`latest`, karena tag
yang berpindah tidak bisa di-rollback dan bisa diam-diam menjalankan image lama.

Yang dilakukan script: cek tag ada di Nexus → `get-credentials` ke kubeconfig sementara (`~/.kube/config`
tidak disentuh) → tunnel lewat bastion bila cluster private → buat namespace bila belum ada → perbarui Secret
pull → cek Secret aplikasi → cek tidak ada objek milik release lain → `helm upgrade --install --wait` dengan
rollback otomatis bila gagal (`--rollback-on-failure` di Helm 4, `--atomic` di Helm 3).

```bash
./deploy.sh ocr-backend ec05d54 --dry-run                           # render manifest saja, tanpa cluster
./deploy.sh ocr-backend ec05d54 -- --set autoscaling.worker.maxReplicas=8
./deploy.sh ocr-backend <tag-sebelumnya>                            # rollback
```

## Ganti project, cluster, atau namespace

Sekali jalan, dari shell:

```bash
GKE_PROJECT=project-lain GKE_CLUSTER=cluster-lain BACKEND_NAMESPACE=ocr-test ./deploy.sh ocr-backend ec05d54
```

Namespace diatur per komponen (`BACKEND_NAMESPACE`, `RBAC_UI_NAMESPACE`); admin UI otomatis diarahkan ke
`BACKEND_NAMESPACE`.

Permanen: ubah `environments/dev.env`. Environment baru (mis. `prd`): salin `environments/dev.env.example` ke
`environments/prd.env.example` (di-commit) dan `environments/prd.env` (lokal), folder `environments/dev/` ke `environments/prd/`, ganti nilainya (termasuk
`NEXUS_PATH=bribrain/prd/...`), lalu `./deploy.sh ocr-backend <tag> --env prd`.

## Cluster private (env `shared`)

`environments/shared.env` menargetkan `gc-bigpool-dev-gke-cluster-01` di project `shared-kubecluster-dev-01`,
dengan namespace per servis: `nilam-ocr-orchestrator` (backend dan Bedrock probe sesuai `shared.env`) dan
`nilam-ocr-rbac-ui` (admin UI).
Control plane-nya hanya punya endpoint private yang dibuka untuk subnet bastion, jadi bila `GKE_BASTION` diisi
script membuka tunnel SOCKS lewat IAP ke bastion itu (`gcloud compute ssh --tunnel-through-iap -- -D`),
memasang `proxy-url` di kubeconfig sementara, dan menutup tunnel saat selesai. Semua tetap dijalankan dari
laptop; bastion tidak perlu helm, docker, atau salinan repo ini. Cek image ke Nexus tetap dari laptop, jadi VPN
harus aktif.

## Redis bersama (env `shared`)

Satu Redis untuk semua team di cluster shared: release dan namespace `shared-redis`, alamat
`shared-redis.shared-redis.svc.cluster.local:6379`, AOF di PVC 5Gi. Pengganti VM Redis dev, yang ada di VPC lain
dan tidak terjangkau dari cluster ini. Bukan HA: restart pod menghentikan Redis semua team beberapa detik.

Node pool shared memakai N4, yang memerlukan Hyperdisk. StorageClass default `standard-rwo` memakai `pd-balanced`
dan tidak bisa di-attach ke N4. Terapkan `environments/shared/redis-storageclass.yaml` sekali sebelum deploy Redis
pertama; perintahnya ada di urutan deploy di bawah.

PVC yang sudah dibuat tidak bisa mengganti `storageClassName`. Sebelum mengganti class, migrasikan data Redis;
jangan hapus PVC yang berisi data.

Isolasi lewat ACL Redis, dari Secret `shared-redis/shared-redis-acl` yang hanya berisi hash password:

- user `default` (tanpa login) hanya boleh `PING`, dipakai probe Kubernetes;
- satu user per team, hanya boleh key dengan prefix miliknya, tanpa perintah `@dangerous` (`FLUSHALL`, `KEYS`,
  `CONFIG`, `MONITOR`, ...) kecuali `INFO` yang dibutuhkan arq;
- user `admin` untuk ops; password-nya di key `ADMIN_PASSWORD` Secret ACL.

Tambah team, atau rotasi password bila dijalankan ulang:

```bash
./scripts/services/redis/user.sh team-b --env shared --to team-b --keys 'team-b:*'
```

Hasilnya Secret `team-b/redis-team-b` berisi `REDIS_URL`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_USERNAME`, dan
`REDIS_PASSWORD`, yang dibaca aplikasi team lewat `secretKeyRef`/`envFrom`. Bila Redis sudah jalan, ACL
dimuat ulang tanpa restart (`ACL LOAD`). Setelah rotasi, restart pod team itu. Aturan untuk team:

- semua key diawali prefix team; nomor DB (`/0`, `/1`) tidak memisahkan apa pun, ACL berlaku di semua DB;
- policy memori `noeviction`, supaya job antrean tidak pernah dibuang: setiap key cache wajib punya TTL, atau
  saat Redis penuh write semua team ditolak;
- arq memakai prefix tetap `arq:*`; dua team yang sama-sama memakai arq berbagi prefix itu, jadi bedakan
  `queue_name` dan sadari job masing-masing saling terlihat.

Image disalin sekali dari Docker Hub ke Nexus, dikunci ke digest yang sudah diuji:

```bash
docker buildx imagetools create \
  --tag new-nexus.gcp.bri.co.id/bribrain/dev/nilam/nilam-ocr-orchestrator/redis:7.4.7-alpine \
  docker.io/library/redis@sha256:02f2cc4882f8bf87c79a220ac958f58c700bdec0dfb9b9ea61b62fb0e8f1bfcf
```

Pertama kali di env `shared`, urutannya:

```bash
./scripts/kube.sh --env shared -- kubectl apply -f environments/shared/redis-storageclass.yaml
./scripts/services/redis/user.sh nilam-ocr --env shared --to nilam-ocr-orchestrator --keys 'ocr ocr:* arq:* datahub:*'
./deploy.sh redis 7.4.7-alpine --env shared
./deploy.sh ocr-backend ec05d54 --env shared    # REDIS_URL dari Secret redis-nilam-ocr
./deploy.sh rbac-ui d25f1de --env shared
```

## NILAM OCR akta

Lima service akta pendirian, masing-masing image, release, Deployment, dan rollback sendiri, tapi satu chart
`charts/ocr-akta`: template kelimanya sama, jadi chart dipasang lima kali dan `--set component=<service>` (diisi
script) memilih service yang dirender. `environments/<env>/ocr-akta.yaml` memuat kelimanya sekaligus, sehingga
URL antar-service (`<NAMA>_SERVICE_URL`) dihitung chart dari `fullnameOverride` + port, tidak ditulis tangan.

| Service | Port | Release | Objek di cluster (Deployment, Service, ServiceAccount, PDB) | Memanggil |
|---|---|---|---|---|
| orchestrator (pintu masuk `POST /v1/extract-ocr`) | 8034 | `ocr-akta-orchestrator` | `ms-bribrain-nilam-ocr-akta-orchestrator` | keempat tahap |
| extraction (render 300 DPI, PaddleOCR, DiT) | 8030 | `ocr-akta-extraction` | `ms-bribrain-nilam-ocr-akta-extraction` | guardrails |
| guardrails (E5, model segmen, penilai buram) | 8031 | `ocr-akta-guardrails` | `ms-bribrain-nilam-ocr-akta-guardrails` | structuring |
| structuring (LLM per segmen) | 8032 | `ocr-akta-structuring` | `ms-bribrain-nilam-ocr-akta-structuring` | scoring |
| scoring (skor field → confidence) | 8033 | `ocr-akta-scoring` | `ms-bribrain-nilam-ocr-akta-scoring` | - |

Image: `$NEXUS_REGISTRY/$AKTA_NEXUS_PATH/ms-bribrain-nilam-ocr-akta-<service>:<tag>`, folder
`bribrain/dev/nilam-ocr-akta` (bukan `NEXUS_PATH` milik orchestrator). Image di-push dari repo
`nilam-ocr-akta`; kelimanya membawa tag SHA monorepo yang sama, jadi `./deploy.sh akta <tag>` cukup satu tag.
Bobot model sudah ikut di image: pod tidak mengunduh apa pun dan tidak butuh identitas GCP.

Namespace: `AKTA_NAMESPACE`, yaitu `nilam-ocr-akta` (dev, cluster ddb) dan `bribrain-ocr-nilam` (shared; kuota
`nilam` habis).

### Secret aplikasi akta

Satu Secret `nilam-ocr-akta-secrets` (`AKTA_SECRET`), dibuat manual seperti `ocr-orchestration`. Tidak dibaca
lewat `envFrom`: tiap pod hanya memasang key miliknya (`services.<service>.secretEnv`, `secretKeyRef`).

| Key | Dipakai | Wajib |
|---|---|---|
| `API_KEY` | kelimanya (diterima dari pemanggil dan dikirim ke tahap berikutnya) | ya |
| `API_KEYS` | kelimanya; key lain yang masih diterima selama rotasi, dipisah koma | tidak |
| `DATABASE_URL` | kelimanya: `postgresql+asyncpg://<user>:<password>@<ip privat>:5432/<db>`, schema `nilam_ocr_akta` | ya |
| `LLM_AUTH_CLIENT_SECRET` | structuring | ya (`STRUCTURING_BACKEND=cloud`) |
| `CACHE_URL` | structuring: cache prompt di Redis bersama, `REDIS_URL` user ACL akta (lihat di bawah). Tanpa key ini tiap pod memakai cache di dalam prosesnya | tidak |
| `ORCHESTRATION_CALLBACK_KEY`, `ORCHESTRATION_API_KEY` | keempat tahap, hanya bila callback dinyalakan | tidak |
| `ELASTIC_APM_SECRET_TOKEN`, `ELASTIC_APM_API_KEY` | kelimanya, hanya bila `apm.serverUrl` diisi | tidak |

```bash
./scripts/kube.sh --env shared -- kubectl create secret generic nilam-ocr-akta-secrets \
  -n bribrain-ocr-nilam --from-env-file=/tmp/akta.env
rm -f /tmp/akta.env
```

Secret dibaca saat pod start: setelah isinya berubah, `kubectl rollout restart` Deployment yang memakainya.

### Sebelum deploy pertama

- Tabel akta (schema `nilam_ocr_akta`) sudah ada di database `DATABASE_URL`; migrasi tidak dijalankan repo ini.
- Empat `LLM_AUTH_*` structuring (bukan rahasia) di `environments/<env>/ocr-akta.yaml`. Selama kosong, render
  structuring gagal dengan pesan yang menyebut key-nya, termasuk `--dry-run`.
- `FILE_URL_ALLOWED_HOSTS`: host MinIO yang boleh dipakai `file_url`. Kosong = hanya host publik.
- Redis cache prompt (opsional): user ACL dengan pola key `nilam_ocr_akta:*`, karena key cache-nya
  `nilam_ocr_akta:nilam_system_prompt:active` (selalu ber-TTL, `PROMPT_CACHE_TTL_SECONDS`). User dengan pola lain
  ditolak Redis (`NOPERM`); structuring tetap jalan tapi membaca prompt dari database di setiap job.
  `REDIS_URL` dari Secret hasilnya jadi `CACHE_URL` di `nilam-ocr-akta-secrets`:

  ```bash
  ./scripts/services/redis/user.sh nilam-ocr-akta --env shared --to bribrain-ocr-nilam --keys 'nilam_ocr_akta:*'
  ```
- Pod menjangkau PaddleOCR PP-StructureV3 `http://10.213.191.187:5000/predict/json`, bukan PP-OCRv6
  `10.213.128.67:8070` milik NPWP, serta identity provider dan LLM (`ap-southeast-3`) untuk structuring.

### Deploy

```bash
./deploy.sh akta <tag> --env shared --dry-run         # kelimanya; selalu dry-run dulu
./deploy.sh akta <tag> --env shared                   # scoring, structuring, guardrails, extraction, orchestrator
./deploy.sh ocr-akta-extraction <tag> --env shared    # satu service; rollback = tag sebelumnya
```

`akta` men-deploy dari tahap terakhir ke orchestrator, supaya tiap tahap baru naik saat tahap tujuan
hand-off-nya sudah ada. Gagal di satu service = berhenti di situ (service sebelumnya tetap di tag baru).

Perilaku yang perlu diketahui:

- Mode poll: `orchestration.callbackEnabled: false`, tanpa `ORCHESTRATION_URL`. Orkestrasi pusat membaca
  `GET /v1/extract-ocr/{request_id}` di orchestrator akta. Untuk callback, isi `orchestration.url` dan
  `callbackEnabled: true` (+ `ORCHESTRATION_CALLBACK_KEY` di Secret).
- HPA mati, satu replika per service, `maxSurge: 0`: rollout tidak memesan pod di atas jatah, jadi service mati
  sebentar selama pod baru menyala. Total request 2,75 CPU / 11 Gi; memory limit = request, tanpa CPU limit.
- extraction dan guardrails: satu job per pod (`PIPELINE_MAX_CONCURRENT_JOBS=1`) dan satu thread torch per CPU
  request. Kapasitas ditambah lewat replika (`autoscaling` per service), bukan job per pod.
- Startup probe memberi waktu muat model (extraction 6 menit, guardrails 10 menit); readiness `/ready`, liveness
  TCP. Grace period tahap panjang 150 detik: job yang berjalan diberi 120 detik selesai, selebihnya diambil ulang
  pod lain setelah lease 300 detik.
- Root filesystem read-only; service hanya menulis ke `/tmp` (emptyDir, juga `HOME`).

Validasi lokal (lint per service, karena `component` wajib):

```bash
for c in orchestrator extraction guardrails structuring scoring; do
  helm lint charts/ocr-akta -f environments/shared/ocr-akta.yaml --set component=$c --strict
done
./deploy.sh akta <tag> --env shared --dry-run | kubeconform -strict -summary
```

## Autoscaling (HPA)

HPA aktif untuk api, worker, dan admin UI (`autoscaling.*` di values chart). Selama HPA aktif, Deployment tidak
menulis `replicas`, supaya `helm upgrade` tidak mereset jumlah pod yang dipilih HPA. Target CPU dihitung dari
`resources.requests`, jadi request harus realistis. Scale-down dibatasi satu pod per menit, dengan jeda
stabilisasi 5 menit (api, UI) dan 10 menit (worker).

## Worker

- Image dan Secret sama dengan api; perintahnya `arq src.workers.ocr_worker.WorkerSettings`.
- `terminationGracePeriodSeconds: 120`: job OCR butuh puluhan detik; default 30 detik memotongnya saat rollout.
- Liveness `arq --check`: membaca health-check key worker di Redis, jadi pod direstart bila worker berhenti
  heartbeat atau Redis tidak terjangkau. Interval heartbeat arq default 1 jam; set `worker.livenessProbe: {}`
  untuk mematikan.
- Tanpa Service dan tanpa readiness probe: worker tidak melayani trafik.
- HPA CPU hanya jaring pengaman: worker kebanyakan menunggu HTTP ke layanan OCR, jadi antrean bisa menumpuk
  saat CPU rendah. Antrean arq berupa sorted set, sehingga scaler Redis list KEDA tidak bisa membacanya;
  scaling berdasarkan panjang antrean butuh metrik custom.
- PodDisruptionBudget `maxUnavailable: 1` (bukan `minAvailable: 1`, yang memblokir drain node bila replika 1).

## Migrasi dari chart lama

Nama objek mengikuti nama repo Bitbucket (`fullnameOverride` di `environments/<env>/*.yaml`): backend
`ms-bribrain-nilam-ocr-orchestrator` (Deployment `-api` dan `-worker`), admin UI `mf-bribrain-nilam-ocr-admin-ui`.

Chart lama (`nilam-ocr-orchestration/deploy`, release `ocr-dev` di namespace `ocr-dev`) memakai nama
`ocr-orchestration`, `ocr-orchestration-api`, `-worker`, dan `ocr-admin-ui`, jadi tidak bentrok: keduanya bisa jalan
berdampingan, juga di namespace yang sama. Deploy, uji, pindahkan konsumen ke Service/IP LoadBalancer baru, lalu
hapus Deployment, Service, dan HPA lama milik release `ocr-dev` (bukan `helm uninstall ocr-dev`, yang juga
menghapus MinIO). Tanpa downtime. Bila ada objek bernama sama milik release lain, script berhenti lebih awal
dengan pesan yang menyebut objeknya.

Release chart ini yang masih memakai nama lama (`ocr-orchestration`, `ocr-admin-ui`) ikut berganti nama pada
deploy berikutnya: Helm membuat objek baru dan menghapus yang lama. FQDN Service backend dan IP LoadBalancer
berubah kecuali memakai IP statis (`service.loadBalancerIP`).

## Standar untuk servis berikutnya

- Satu chart per komponen yang di-deploy terpisah; api dan worker yang berbagi image tetap satu chart.
- Beberapa service dengan template sama (akta): satu chart generik yang dipasang sekali per service, dipilih
  dengan `component`, tetap satu release, image, dan rollback per service.
- Label `app.kubernetes.io/{name,instance,component,version,part-of}`; selector hanya name, instance, component.
- Image dari Nexus dengan tag sha yang immutable dan `pullPolicy: IfNotPresent`.
- Rahasia di Secret yang dibuat di luar chart (`existingSecret`), tidak pernah di values.
- Readiness memeriksa dependensi; liveness hanya proses itu sendiri, supaya gangguan database tidak memicu
  restart massal.
- Tanpa CPU limit (throttling merusak latensi), memory limit tetap ada; HPA tanpa `replicas` di Deployment;
  PDB `maxUnavailable`.
- `runAsNonRoot` dengan UID numerik, `seccompProfile: RuntimeDefault`, drop semua capability,
  `automountServiceAccountToken: false`.
- Script: tag wajib, cek image sebelum deploy, `--wait` dengan rollback otomatis, `--dry-run` tanpa cluster.

Validasi lokal: `helm lint charts/<chart> -f environments/dev/<chart>.yaml --strict` dan
`./deploy.sh <service> <tag> --dry-run | kubeconform -strict -summary`.
