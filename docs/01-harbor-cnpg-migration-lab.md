# 커스텀 docker·helm: Nexus → Harbor 2.7(ChartMuseum) on CloudNativePG — 전체 이관 실측 (2026-11-03)

범위: Nexus 는 그대로 유지. Nexus 의 **커스텀 docker 이미지(docker-hosted)·helm 차트(helm-hosted)만** Harbor 로 옮긴다. Harbor DB 는 CNPG.
랩: k8s-core cp1 단일 노드(arm64, 2 CPU / 2.9 GiB), 폐쇄망 구조(노드는 인터넷 불가, containerd 가 docker.io/ghcr.io/quay.io/registry.k8s.io → 내부 레지스트리 172.16.141.10:5000 미러).
원본: nexus6(3.82.0-08 CE). 산출물: `~/nexus-lab/harbor-cnpg/`.

## 0. 결정 버전
| 구성 | 버전 | 비고 |
|---|---|---|
| CNPG operator | **1.30.1** (Helm chart cloudnative-pg 0.29.1) | 2026-11 최신 |
| PostgreSQL | **16.15** (`ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm`) | Harbor 2.7 스키마 정상 생성 확인 |
| Harbor | **2.7.0** (chart harbor 1.11.0) | ChartMuseum 내장 마지막 계열 — 클래식 `helm repo add` 유지 |
| 랩 이미지 | `ghcr.io/octohelm/harbor/*:v2.7.0` | arm64 빌드. **운영(amd64)은 차트 기본 `goharbor/*:v2.7.0`** |

## 1. 폐쇄망 반입 (registry VM 에서 skopeo, k8s-core `mirror-images.sh` 규칙: 호스트 부분 제거)
- `ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1` → `172.16.141.10:5000/cloudnative-pg/cloudnative-pg:1.30.1` (`--all`)
- `ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm` → 같은 규칙
- Harbor 2.7 이미지는 기존 harbor27 설치 때 반입돼 있음. 차트 tgz(cloudnative-pg-0.29.1.tgz, harbor-1.11.0.tgz)는 Mac 에서 받아 로컬 파일로 설치.
- 이 클러스터는 이번 반입 외 다른 설정 변경 없이 미러로 정상 pull.

## 2. CNPG 설치 + Harbor 용 PG 클러스터
- Helm 판: `helm install cnpg cloudnative-pg-0.29.1.tgz -n cnpg-system --create-namespace --set image.tag=1.30.1` → 8초 Running, CRD 11개.
- kubectl 판(검증만): `cnpg-1.30.1.yaml`(릴리스 매니페스트 1.29MB). **일반 `kubectl apply` 는 `metadata.annotations: Too long ... 262144 bytes` 로 실패 → `kubectl apply --server-side`** 필수. 리소스 이름이 Helm 판(`cnpg-cloudnative-pg`)과 달라(`cnpg-controller-manager`) **둘 중 하나만** 설치.
- `harbor-pg.yaml`: instances 1, bootstrap.initdb(database registry / owner harbor), local-path 2Gi, max_connections 200 → **30초에 healthy**. 서비스 `harbor-pg-rw/ro/r`, Secret `harbor-pg-app`(키 username/password/host/uri…).

## 3. Harbor 2.7 설치 (외부 DB = CNPG)
`values-harbor-cnpg.yaml` 핵심:
- `database.type: external`, `external.host: harbor-pg-rw.harbor-cnpg.svc`, `username: harbor`, `coreDatabase: registry`, **`existingSecret: harbor-pg-app`** (차트가 그 Secret 의 키 `password` 를 그대로 읽음 → 비밀번호 복사 불필요, CNPG 가 회전해도 Secret 하나만), **`sslmode: require`** (CNPG 기본 TLS)
- **`maxOpenConns: 50`, `maxIdleConns: 10`** — 차트 기본 900 은 PG max_connections 를 넘어서 부하 시 연결 고갈
- trivy/notary/metrics off, chartmuseum on, NodePort 30004
결과: 설치 후 40초에 전부 Running. PG 에 **테이블 49개, schema_migrations 100**, Harbor 연결 3개 모두 `ssl=t`. 첫 기동 때 jobservice 가 redis 준비 전이라 2회 재시작 후 안정(기동 순서 경합, 정상).

## 4. Harbor 사전 구성
프로젝트 `dlops`(이미지, 비공개)·`charts`(차트, 비공개). 시스템 로봇 `robot$migrator`: dlops = repository pull/push·artifact read·tag create/list, charts = helm-chart read·helm-chart-version create/read·repository pull.
**함정: 로봇 이름의 `$`** — 비밀값을 `ROBOT_NAME=robot$migrator` 로 저장해 `source` 하면 `$migrator` 가 셸 변수로 풀려 사용자명이 `robot` → docker 는 `trying to reuse blob … `(인증 실패), 차트 업로드는 401. 작은따옴표로 저장(`ROBOT_NAME='robot$migrator'`)하자 해결. CI 변수·Secret 생성 시에도 동일.
로봇은 차트 '전체 목록' API(`/api/chartrepo/charts/charts`)는 403, 개별 버전 조회·업로드·index.yaml·helm repo 는 정상.

## 5. 원본 데이터 (nexus6)
docker-hosted: dlops/app1:1.0·1.1·latest(셋 다 같은 digest, docker v2s2), dlops/app2:2.0(OCI), dlops/multi:1(OCI index arm64+amd64), dlops/pybase:3.12(python 3.12-alpine ≈60MB), 이후 증분용 dlops/web:1.0(nginx). helm-hosted: h27a/h27b/h27c × 0.1.0/0.2.0.

## 6. 이관 (`migrate-nexus-to-harbor.sh`, 셸: curl + python3 + skopeo)
- 목록: Nexus REST `GET /service/rest/v1/components?repository=<repo>` (continuationToken 끝까지) → docker 는 name/version, helm 은 .tgz 자산의 downloadUrl·sha256.
- docker: `skopeo copy --all --preserve-digests` Nexus 커넥터 → `<harbor>/<경로>:<태그>`. 경로 규칙: Nexus 이미지 이름의 첫 조각이 Harbor 프로젝트(`dlops/app1` → `harbor/dlops/app1`), 조각 없는 이름은 기본 프로젝트로. 복사 전후 manifest raw 의 sha256 을 비교(같으면 SKIP).
- helm: downloadUrl 로 받고 Nexus 가 준 sha256 으로 검증 → `POST /api/chartrepo/<project>/charts`(multipart, 필드명 `chart`) → 201. 이미 `GET /api/chartrepo/<project>/charts/<name>/<ver>` 가 200 이면 SKIP.
| 실행 | docker | helm |
|---|---|---|
| 1차(로봇 `$` 버그) | 실패 6 | 401 ×6 |
| 2차 | **복사 6, digest 전부 일치**(app1×3 4bdb4ac63839, app2 5ca6a002c5c3, multi index ba1199205458, pybase 5642cb13b1fc) | **업로드 6** |
| 3차(재실행) | SKIP 6 | SKIP 6 |
| 4차(원본에 web:1.0 추가 뒤 = 컷오버 직전 델타) | **복사 1, SKIP 6** | SKIP 6 |

## 7. 사용자 관점 검증
- helm(v4.3.0): `helm repo add hbcharts http://<harbor>/chartrepo/charts --username 'robot$migrator'` → `helm search repo -l` 6버전 → `helm pull` 6개 **원본과 바이트 동일 6/6**, index.yaml digest 도 원본 sha256 과 일치.
- 클러스터(containerd): 노드 `/etc/containerd/certs.d/172.16.141.11:30004/hosts.toml`(HTTP) 추가 — `config_path` 방식이라 containerd 재시작 불필요. 네임스페이스에 로봇으로 `imagePullSecret` 생성.
  - `helm upgrade --install web hbcharts/h27a --version 0.2.0 --set image.repository=<harbor>/dlops/web …` → **Running, 서비스 200**, imageID digest 63ffc0d1f14e = 이관 digest.
  - `dlops/pybase:3.12` 파드 → `pybase-ok aarch64 3.12.16`, Succeeded.
  - `dlops/multi:1`(태그) → repoDigest = index ba1199205458(원본과 동일), 노드가 arm64 선택. (컨테이너는 CMD 없는 더미라 start 실패 — 이관 무관)

## 8. 운영 점검
### 8.1 CNPG 파드 재시작(단일 인스턴스) 시 Harbor
| 설정 | 옛 파드 종료 | 새 파드 ready | pull 실패 | API·push 실패 |
|---|---|---|---|---|
| 기본(`smartShutdownTimeout` 180) | **182초** | 193초 | 11초 | 11초 |
| `smartShutdownTimeout: 15` | **16초** | 28초 | 3초 | 13초 |
- 기본에서 182초가 걸리는 이유: PG '스마트 종료'가 클라이언트 연결이 끊기길 기다리는데 Harbor 커넥션 풀은 스스로 끊지 않음 → 타임아웃까지 그냥 대기. 그동안은 기존 연결로 정상 동작.
- DB 가 실제로 없는 구간에는 **pull 도 401**(Harbor 인증·토큰 검증에 DB 필요) — DB 장애 = 레지스트리 장애. Harbor 파드는 재시작 없이 자동 복구.
- 운영 권장: instances 3(+ 노드 분산)으로 두고 계획 작업은 switchover(`kubectl cnpg promote`) — 단일이면 smartShutdownTimeout 축소.
### 8.2 DB 백업·복구
`kubectl exec harbor-pg-1 -c postgres -- pg_dump -U postgres -d registry -Fc` (Harbor 무중단) 156KB → 새 CNPG 클러스터(harbor-pg-restore, 20초 healthy)에 `pg_restore` → project 3 / repository 6 / artifact 8 / tag 150 / robot 1 / harbor_user 2 / schema 100 **원본과 동일**, 49 테이블 소유자 harbor 유지. 시험 후 삭제.
- **DB 만으로는 Harbor 백업이 아니다**: 이미지 blob 은 registry PVC(또는 S3), 차트는 chartmuseum PVC 에 있다 → DB + 두 저장소를 같은 시점으로 백업.

## 9. 랩 상태(종료 시점)
- 가동: cnpg-system(operator), harbor-cnpg(harbor-pg + harborcnpg 7개 파드, NodePort 30004). 시험 앱 ns migtest 삭제.
- **ns harbor(Harbor 2.13) 는 메모리 확보를 위해 replicas 0 으로 내려 둠** — 원래 replica 는 scratchpad `harbor-replicas.txt`(전부 1). 복원: `kubectl -n harbor scale deploy,sts --all --replicas=1` (단 harbor-cnpg 와 동시 가동 시 노드 가용 메모리 763MB 로 빠듯).
- cp1 containerd 에 `/etc/containerd/certs.d/172.16.141.11:30004/hosts.toml` 추가(지우면 원복).
- 비밀값(Harbor admin, 로봇 secret)은 scratchpad `hc.admin`, `hc.robot` 에만.

# 2차: Harbor 최신 세대(2.14.0, ChartMuseum 없음 → helm OCI) + CNPG 로 재이관 (2026-11-03 14:55~15:04)
사용자 결정: Harbor 는 최신으로. 공식 `goharbor/*:v2.15.4`(chart 1.19.4)는 **amd64 단일 아키**라 arm64 랩 노드에서 못 띄움 → 랩은 arm64 빌드가 있는 최신인 **2.14.0**(`ghcr.io/octohelm/harbor/*:v2.14.0`, chart 1.18.0). 운영(amd64)은 2.15.4 공식 이미지에 같은 values 키를 쓴다. 두 버전 모두 ChartMuseum 이 없는 세대라 이관·운영 방식은 동일.

## 1. 준비
- 2.7 환경(release harborcnpg, CNPG harbor-pg, PVC) 삭제 → 메모리 확보. 같은 `harbor-pg.yaml` 로 CNPG 클러스터 재생성(24초 healthy, Secret `harbor-pg-app`).
- 이미지 8종(core, jobservice, registry-photon, registryctl, portal, nginx-photon, redis-photon, exporter) `--override-os linux --override-arch arm64` 로 내부 레지스트리에 반입: 45초.
- chart 1.18.0 차이: `chartmuseum:` 섹션 없음, `existingSecretAdminPassword`/`existingSecretAdminPasswordKey` 로 관리자 비밀번호를 Secret 에서 읽음(1.11 에는 없던 키), `database.external.*` 키는 동일(`existingSecret`, `sslmode`, `maxOpenConns`).
- values: `values-harbor214-cnpg.yaml`. 관리자 Secret `harbor-admin`(키 HARBOR_ADMIN_PASSWORD) 먼저 생성.

## 2. 설치 결과
`helm install harbor214 harbor-1.18.0.tgz -n harbor-cnpg -f values-harbor214-cnpg.yaml` → 전 파드 Ready **61초**. jobservice 2회 재시작(redis 준비 전, 정상). systeminfo `harbor_version=v2.14.0`, `with_chartmuseum` 없음. PG: 테이블 49, **schema_migrations 170**(2.7 은 100), Harbor 연결 3/3 TLS.

## 3. Harbor 구성 (2.8+ 는 차트가 OCI 아티팩트 → 권한 모델이 이미지와 동일)
프로젝트 dlops(이미지)·charts(차트). 로봇 `robot$migrator` 권한: 두 프로젝트 모두 repository pull/push, artifact read/list, tag create/list. (2.7 의 helm-chart 리소스는 없음.) 비밀값 파일은 작은따옴표로.

## 4. 이관 (`migrate-nexus-to-harbor-oci.sh`)
docker 부분은 1차와 동일. helm 부분만 변경: 존재 확인은 `GET /api/v2.0/projects/charts/repositories/<차트명>/artifacts/<버전>`(200 이면 SKIP), 업로드는 `helm registry login` 후 **`helm push <tgz> oci://<harbor>/charts`**. helm ≥3.8 필요(랩 4.3.0, http 라 `--plain-http`).
| 실행 | docker | helm |
|---|---|---|
| 1차 | **복사 7, digest 전부 일치** (app1×3, app2, multi index ba1199205458, pybase, web) | **push 6** (OCI digest 는 tgz sha 와 다름 — 정상. Harbor 가 CHART 타입으로 인식, 태그=차트 버전) |
| 2차(재실행) | SKIP 7 | SKIP 6 |

## 5. 사용자 관점 검증
- `helm pull oci://<harbor>/charts/<이름> --version <버전>` 6개 → **원본 tgz 와 바이트 동일 6/6**. `helm show chart oci://…` 정상.
- **`helm repo add`/`helm search repo` 는 없다.** 버전 목록은 Harbor API(`/api/v2.0/projects/charts/repositories/<이름>/artifacts`) 또는 UI 로 본다. 로봇은 이 artifacts 목록 200, 프로젝트의 **repositories 목록은 403**(admin 은 200) — 전체 차트 목록을 긁는 스크립트는 admin 계정이나 별도 권한 필요.
- 클러스터: `helm upgrade --install web oci://<harbor>/charts/h27a --version 0.2.0 --set image.repository=<harbor>/dlops/web …` → Running, 서비스 200, imageID 63ffc0d1f14e(이관 digest). pybase 파드 `pybase-ok aarch64`. multi:1 repoDigest = index(…7201f6), arm64 선택.

## 6. 운영 점검 (2.14)
- CNPG 파드 재시작(`smartShutdownTimeout: 15`): 옛 파드 종료 16s, 새 파드 ready 28s, **pull·API·push 실패 구간 11초**(2.7 때와 동일 패턴; API 는 이번엔 500 으로 응답).
- `pg_dump -Fc` 무중단 157KB, project 3 / repository 9 / artifact 14 / schema 170.
- 2.7 과 달리 차트가 registry 저장소(blob)에 들어가므로 **백업 대상은 DB + registry PVC 두 곳**(chartmuseum PVC 없음).

## 7. 랩 상태
harbor-cnpg: harbor-pg + harbor214 7파드(NodePort 30004) 가동. ns harbor(2.13) 는 replicas 0 유지. 노드 가용 메모리 855MB. 비밀값은 scratchpad `hc.admin`, `hc.robot214`.
