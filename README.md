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
| MinIO untuk service OCR per dokumen (env `shared`) | `charts/minio` | `./deploy.sh minio` | `minio` (build dari source) |

## Struktur

```
charts/<chart>/            chart generik, tanpa nilai khusus environment
environments/<env>.env     target GKE + path Nexus + nama release (tidak di-commit; salin dari <env>.env.example)
environments/<env>/*.yaml  override values per chart untuk environment itu
scripts/services/<service>/  script per service: deploy, operasi, dan probe
scripts/                     helper bersama `_lib.sh`, `kube.sh`, `secret.sh` (ubah satu key Secret), `env.sh` (lihat env)
deploy.sh                    entrypoint; bisa deploy backend lalu UI lewat `application`
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
  -n bribrain-ocr-nilam --from-env-file=/tmp/ocr.env                 # cluster private
```

Untuk konfigurasi Bedrock aplikasi, tambahkan tiga variabel ini ke file `/tmp/ocr.env`:

- `AWS_BEARER_TOKEN_BEDROCK` — Bedrock API key; rahasia, dan tidak memerlukan `AWS_ACCESS_KEY_ID` atau `AWS_SECRET_ACCESS_KEY`.
- `AWS_REGION_NAME` — region AWS, misalnya `ap-southeast-3`.
- `BEDROCK_MODEL_ID` — ID model yang dipakai aplikasi.

Chart meneruskan isi Secret `ocr-orchestration` ke container API dan worker tanpa memerlukan perubahan values. Pastikan image aplikasi membaca nama variabel tersebut. Secret `bedrock-probe-credentials` di bagian probe di bawah terpisah dan hanya dipakai oleh skrip tes konektivitas.

URL di Secret itu (`REDIS_URL`, `OCR_<TYPE>_SERVICE_URL`, `DATAHUB_SERVICE_URL`) pakai FQDN
`<service>.<namespace>.svc.cluster.local` bila servisnya ada di namespace lain.

Ubah satu key tanpa membuat ulang Secret: `./scripts/secret.sh --env shared [-n <namespace>]`. Ketik nama Secret,
pilih key (nomor atau nama), ketik nilai baru dua kali (tersembunyi); di akhir script menawarkan restart api/worker.
Lihat isinya: `./scripts/env.sh --env shared [<secret> | deploy/<nama>] [--reveal]` (bawaan: Secret
`$BACKEND_SECRET`; `deploy/<nama>` = env yang benar-benar dilihat container). Nilai rahasia disamarkan tanpa `--reveal`.

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
dengan backend dan admin UI di namespace `bribrain-ocr-nilam` (Bedrock probe di `nilam`). Resource api, worker, dan
UI di cluster ini: request CPU 200m dan memory 512Mi, limit CPU 300m dan memory 512Mi
(`environments/shared/*.yaml`).
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
./scripts/services/redis/user.sh nilam-ocr --env shared --to bribrain-ocr-nilam --keys 'ocr ocr:* arq:* datahub:*'
./deploy.sh redis 7.4.7-alpine --env shared
./deploy.sh ocr-backend ec05d54 --env shared    # REDIS_URL dari Secret redis-nilam-ocr
./deploy.sh rbac-ui d25f1de --env shared
```

## MinIO (env `shared`)

Object storage single-node untuk service OCR per dokumen (KTP, NIB, NPWP, slip gaji, ...): release
`nilam-ocr-minio` di namespace `bribrain-ocr-nilam`, PVC 20Gi Hyperdisk. Alamat dalam cluster:
`http://nilam-ocr-minio.bribrain-ocr-nilam.svc.cluster.local:9000` (API S3) dan `:8080` (console). Pengganti MinIO
di cluster dev (`ocr-dev/minio`, IP publik `34.101.120.81`), yang tidak terjangkau dari cluster shared. Bukan HA:
restart pod menghentikan object storage semua service beberapa detik.

Chart diporting dari `nilam-ocr-orchestration/deploy/templates/minio.yaml`: image, port, dan sesi console 168h
sama. Bedanya: image dari Nexus, root credential dari Secret di luar chart, pod non-root dengan root filesystem
read-only, dan Service ClusterIP. LoadBalancer (`minio-public` di chart lama) jadi opsional lewat
`externalService.enabled`; mati secara default karena HTTP tanpa TLS.

Sekali di awal:

```bash
# Image hasil build nilam-ocr-orchestration/deploy/minio/Dockerfile, disalin dari GAR ke Nexus
docker buildx imagetools create \
  --tag new-nexus.gcp.bri.co.id/bribrain/dev/nilam/nilam-ocr-orchestrator/minio:RELEASE.2025-04-22T22-12-26Z \
  asia-southeast2-docker.pkg.dev/common-cicd-dev-01/gc-bribrain-dev-gar-temp-01/minio:RELEASE.2025-04-22T22-12-26Z

# Root credential acak, tanpa lewat argumen shell
./scripts/kube.sh --env shared -- bash -ceu '
  d=$(mktemp -d); trap "rm -rf $d" EXIT
  printf admin > "$d/MINIO_ROOT_USER"
  openssl rand -hex 24 | tr -d "\n" > "$d/MINIO_ROOT_PASSWORD"
  kubectl create secret generic "$MINIO_SECRET" -n "$MINIO_NAMESPACE" \
    --from-file="$d/MINIO_ROOT_USER" --from-file="$d/MINIO_ROOT_PASSWORD"
'
./deploy.sh minio RELEASE.2025-04-22T22-12-26Z --env shared
```

Console di `http://nilam-ocr-minio-console.bribrain.dev.gcp.bri.co.id` (jaringan BRI/VPN), login dengan root dari
Secret `nilam-ocr-minio-root`. Buat bucket dan **access key terpisah** per service di sana; root credential jangan
dipakai aplikasi. Console di port 8080, bukan 9001, karena firewall L7 baru terbukti meloloskan 8000/8080. Host-nya
satu **Ingress rule** di Ingress bersama nilam (lihat "Ingress"); chart memasang NEG dan BackendConfig (health check
`/`, timeout 300 s) di port console. Root password harus kuat sebelum console dibuka ke jaringan BRI (ganti dengan
`./scripts/secret.sh --env shared`, key `MINIO_ROOT_PASSWORD`, lalu restart).

```bash
./scripts/kube.sh --env shared -- kubectl patch ingress ms-bribrain-nilam-ocr-paddle-ppocr-v6-ingress -n bribrain-ocr-nilam --type json -p '[
 {"op":"test","path":"/spec/rules/0/host","value":"ms-bribrain-nilam-ocr-paddle-ppocr-v6.bribrain.dev.gcp.bri.co.id"},
 {"op":"add","path":"/spec/rules/-","value":{"host":"nilam-ocr-minio-console.bribrain.dev.gcp.bri.co.id","http":{"paths":[{"path":"/","pathType":"Prefix","backend":{"service":{"name":"nilam-ocr-minio","port":{"name":"console"}}}}]}}}
]'
# tanpa Ingress: port-forward lalu buka http://localhost:9001
./scripts/kube.sh --env shared -- kubectl port-forward -n bribrain-ocr-nilam svc/nilam-ocr-minio 9001:8080
```

Service per dokumen memakai `MINIO_ENDPOINT=nilam-ocr-minio.bribrain-ocr-nilam.svc.cluster.local:9000` dan
`MINIO_SECURE=false`. Pindah data dari MinIO dev dengan `mc mirror` dari laptop (VPN menjangkau keduanya):

```bash
./scripts/kube.sh --env shared -- kubectl port-forward -n bribrain-ocr-nilam svc/nilam-ocr-minio 9000:9000  # terminal lain
mc alias set old http://34.101.120.81:9000 <access-key-lama> <secret-key-lama>
mc alias set new http://127.0.0.1:9000 admin <root-password-baru>
mc mb new/ocr-branch && mc mirror old/ocr-branch new/ocr-branch
```

## Ingress (env `shared`)

Backend dan admin UI dibuka lewat Ingress `gce-internal` (internal Application LB, terjangkau dari jaringan BRI/VPN),
bukan Service LoadBalancer: GKE tidak bisa membuat firewall LoadBalancer di Shared VPC.

| Host (HTTP) | Service |
|---|---|
| `ms-bribrain-nilam-ocr-orchestrator.bribrain.dev.gcp.bri.co.id` | `ms-bribrain-nilam-ocr-orchestrator` (backend) |
| `mf-bribrain-nilam-ocr-admin-ui.bribrain.dev.gcp.bri.co.id` | `mf-bribrain-nilam-ocr-admin-ui` (admin UI) |
| `nilam-ocr-minio-console.bribrain.dev.gcp.bri.co.id` | `nilam-ocr-minio` port `console` (MinIO console, lihat "MinIO") |

DNS wildcard `*.bribrain.dev.gcp.bri.co.id` mengarah ke `10.213.192.196` (`gc-bribrain-dev-ilb-nilam-01`), IP
Ingress paddle `ms-bribrain-nilam-ocr-paddle-ppocr-v6-ingress`. Di GKE satu Ingress = satu LB dan satu IP:port hanya
bisa dipakai satu Ingress, jadi host kita menumpang sebagai **Ingress rule** di Ingress paddle itu (Ingress bersama
nilam), bukan Ingress sendiri. Chart cukup memasang anotasi NEG dan BackendConfig (timeout 60 s, health check =
path `readinessProbe`) di Service (`ingress.enabled: true`, `ingress.create: false`). Health check ditulis eksplisit
karena GKE hanya menyalin `readinessProbe` dari pod yang sedang jalan saat backend dibuat; tanpa itu LB mengecek `GET
/`, yang dijawab API dengan 404.

Rule ditambahkan sekali (sepengetahuan tim paddle; kalau Ingress itu di-apply ulang dari YAML/Rancher mereka, rule
ini hilang dan host kita kembali 404). Backup dulu, `test` membatalkan patch bila isinya tidak seperti yang
diharapkan:

```bash
./scripts/kube.sh --env shared -- kubectl get ingress -n bribrain-ocr-nilam ms-bribrain-nilam-ocr-paddle-ppocr-v6-ingress -o yaml > paddle-ingress-backup.yaml
./scripts/kube.sh --env shared -- kubectl patch ingress ms-bribrain-nilam-ocr-paddle-ppocr-v6-ingress -n bribrain-ocr-nilam --type json -p '[
 {"op":"test","path":"/spec/rules/0/host","value":"ms-bribrain-nilam-ocr-paddle-ppocr-v6.bribrain.dev.gcp.bri.co.id"},
 {"op":"add","path":"/spec/rules/-","value":{"host":"ms-bribrain-nilam-ocr-orchestrator.bribrain.dev.gcp.bri.co.id","http":{"paths":[{"path":"/","pathType":"Prefix","backend":{"service":{"name":"ms-bribrain-nilam-ocr-orchestrator","port":{"number":80}}}}]}}},
 {"op":"add","path":"/spec/rules/-","value":{"host":"mf-bribrain-nilam-ocr-admin-ui.bribrain.dev.gcp.bri.co.id","http":{"paths":[{"path":"/","pathType":"Prefix","backend":{"service":{"name":"mf-bribrain-nilam-ocr-admin-ui","port":{"number":80}}}}]}}}
]'
```

Cek dan tes (dari jaringan BRI/VPN):

```bash
./scripts/kube.sh --env shared -- kubectl get ingress -n bribrain-ocr-nilam ms-bribrain-nilam-ocr-paddle-ppocr-v6-ingress \
  -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/backends}{"\n"}'          # semua HEALTHY
curl -i http://ms-bribrain-nilam-ocr-orchestrator.bribrain.dev.gcp.bri.co.id/health
curl -I http://mf-bribrain-nilam-ocr-admin-ui.bribrain.dev.gcp.bri.co.id/
```

- `503 no healthy upstream` = backend UNHEALTHY: cek pod Ready dan health check LB (`gcloud compute health-checks
  describe <backend k8s1-...> --region asia-southeast2`). `404 backend NotFound` = rule host-nya tidak ada di Ingress.
- Deployment `0/0` tidak dinaikkan oleh helm maupun HPA (HPA berhenti di `replicas: 0`); naikkan sekali dengan
  `kubectl scale deploy ... --replicas=1`.
- Ingress sendiri per chart masih bisa dipakai (`ingress.create: true`, `host`, anotasi
  `kubernetes.io/ingress.regional-static-ip-name`), asal tim infra me-reserve IP internal baru dan record DNS A untuk
  host-nya (record khusus menang atas wildcard).
- Port pod harus diizinkan firewall L7 di host project `common-sharenet-dev-02` (sumber proxy-only
  `10.213.194.0/25` dan health check `130.211.0.0/22`, `35.191.0.0/16`). 8000 dan 8080 sudah terbukti jalan
  (brimo-va, paddle), karena itu API di env ini memakai port 8000, bukan 8100. Kalau backend Ingress `UNHEALTHY`,
  minta tim infra membuka port itu.
- HTTPS butuh host langsung di bawah `gcp.bri.co.id`: sertifikat `gc-bribrain-dev-sslp-app-01` (`*.gcp.bri.co.id`)
  tidak mencakup `*.bribrain.dev.gcp.bri.co.id`. Untuk HTTPS, ganti `host` dan tambahkan anotasi
  `ingress.gcp.kubernetes.io/pre-shared-cert: gc-bribrain-dev-sslp-app-01`.

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
