# Harbor 2.7.0(ChartMuseum 내장) + 엔드포인트 nginx(njs) 로 Nexus helm 경로 치환 검증

- 목적: 기존 Nexus helm 경로 `/repository/helm-hosted/` 를 별도 Python 변환기(helm-adapter) 없이 엔드포인트 nginx 만으로 Harbor 2.7 chartrepo 에 매핑할 수 있는지.
- 비밀값(admin 비번, CI 비번)은 이 문서에 적지 않는다. 명령에는 `$HPW`(admin), `$CIPW` 로 표기.

## 0. 사전 상태 (2026-10-07 22:08:39 KST)
- 클러스터: 단일 노드 cp1(172.16.141.11) v1.34.11, 2 vCPU, 메모리 2896Mi(free 기준 available 1448Mi), / 19G 여유
- ns harbor: Harbor 2.13.2 (chart 1.17.2) 7 pod Running, NodePort 30002
- 이미지 공급: containerd hosts.toml 이 ghcr.io → 172.16.141.10:5000(registry:2) 미러 → v2.7.0 이미지를 미러에 넣어야 한다 (logs/harbor-k8s/progress.md 15행과 동일 방식)
- 엔드포인트: podman nexus-endpoint, nginx/1.27.5 (docker.io/library/nginx:1.27-alpine), njs 0.8.10 패키지 포함(`/etc/nginx/modules/ngx_http_js_module.so` 존재) → 컨테이너 재생성 불필요
- nexus-endpoint 원래 run 명령(podman inspect CreateCommand):
  `podman run -d --name nexus-endpoint --network nexuslab --ip 10.89.200.31 -p 127.0.0.1:19000:19000 -p 127.0.0.1:19001:19001 -v ./harbor/endpoint/nginx.conf:/etc/nginx/nginx.conf:ro -v ./harbor/endpoint/active:/etc/nginx/active -v ./logs/endpoint:/var/log/nginx docker.io/library/nginx:1.27-alpine`
  → njs 스크립트는 RW 마운트인 `harbor/endpoint/active/` (컨테이너 `/etc/nginx/active/`) 에 둔다
- 백업: `cp -p ~/nexus-lab/harbor/endpoint/nginx.conf ~/nexus-lab/logs/harbor27/nginx.conf.before` (4717 bytes, 원본 inode 242449221)
- chart: `helm search repo harbor/harbor --versions` → **1.11.0 = appVersion 2.7.0** (1.11.4=2.7.4). 1.11.0 사용. 기본 values 에 `chartmuseum.enabled: true`, `absoluteUrl: false`(613–620행)
- helm 은 사용자 설정 격리: HELM_REPOSITORY_CONFIG/CACHE/REGISTRY_CONFIG = logs/harbor27/helmhome/

## 1. Harbor 2.7.0 설치 (2026-10-07 22:11:47 KST)
- 이미지 미러 적재 (Mac): `skopeo copy --override-arch arm64 --override-os linux --dest-cert-dir <scratchpad>/certs docker://ghcr.io/octohelm/harbor/<n>:v2.7.0 docker://172.16.141.10:5000/octohelm/harbor/<n>:v2.7.0` × 10종 → 10/10 OK, 총 68s (image-seed.log). chartmuseum-photon 확인: `arm64 linux sha256:0815066d…`
- values: logs/harbor27/values.yaml (NodePort 30003, externalURL http://172.16.141.11:30003, chartmuseum.enabled=true, absoluteUrl=false, trivy/notary/metrics off, local-path)
  - chart 1.11.0 에는 `existingSecretAdminPassword` 키가 없음 → `--set harborAdminPassword="$HPW"` (ns harbor Secret harbor-admin 값 재사용, values 파일엔 미기재)
- `helm template … | grep image:` → 9개 이미지 전부 ghcr.io/octohelm/harbor/*:v2.7.0 (goharbor/* 없음)
- 22:10:33 `helm install harbor27 harbor-1.11.0.tgz -n harbor27 --create-namespace -f values.yaml --set harborAdminPassword="$HPW"` → deployed rev 1
- 22:11:27 `kubectl -n harbor27 wait --for=condition=Ready pod --all` → 8 pod 전부 Ready (**54s**). jobservice 는 core 기동 전 2회 재시작 후 정상(Harbor 통상 현상)
  ```
  NAME                                   READY   STATUS    RESTARTS      AGE
  harbor27-chartmuseum-889857d66-zfr4l   1/1     Running   0             74s
  harbor27-core-86f8698dc-d6ttv          1/1     Running   0             74s
  harbor27-database-0                    1/1     Running   0             74s
  harbor27-jobservice-6749997978-qkj5v   1/1     Running   2 (59s ago)   74s
  harbor27-nginx-76bcfd89d4-p7wbk        1/1     Running   0             74s
  harbor27-portal-5bcc99c89-p8wzk        1/1     Running   0             74s
  harbor27-redis-0                       1/1     Running   0             74s
  harbor27-registry-5d6695996f-8xhx2     2/2     Running   0             74s
  service/harbor  NodePort  80:30003/TCP
  ```
- `curl http://172.16.141.11:30003/api/v2.0/systeminfo` → `{"auth_mode":"db_auth","harbor_version":"v2.7.0-6113469a",...}`
- 자원: 설치 후 cp1 `free -m` available 1208Mi (설치 전 1448Mi) → **ns harbor 의 2.13 은 scale 0 하지 않음** (2.13 ping 30002 = 200 유지)

## 2. Harbor 2.7 chart API 직접 검증 (Mac → 172.16.141.11:30003) (2026-10-07 22:12~22:16 KST)
준비 (API):
- `POST /api/v2.0/projects {"project_name":"charts","metadata":{"public":"false"}}` → 201
- `POST /api/v2.0/users` ci-helm (비번은 scratchpad 파일에만) → 201, `POST /api/v2.0/projects/charts/members {"role_id":2(developer)}` → 201
- `GET /api/v2.0/systeminfo`(admin) → `with_chartmuseum= True v2.7.0-6113469a`
- 시험 차트: `helm create h27a/h27b/h27c` → `helm package --version …` 25개 (logs/harbor27/charts/)

업로드 방식별 응답 (엔드포인트 설계의 핵심 근거):

| 요청 | 응답 |
|---|---|
| `curl -u admin -F chart=@h27a-0.1.0.tgz …/api/chartrepo/charts/charts` (multipart) | **201** `{"saved":true}` |
| `curl -u ci-helm -F chart=@h27b-1.0.0.tgz …/api/chartrepo/charts/charts` | **201** |
| 같은 버전 재업로드(-F h27b-1.0.0) | **201** (덮어쓰기 허용 — Nexus hosted 의 redeploy 정책과 다름) |
| `curl -u ci-helm -T h27a-0.2.0.tgz …/api/chartrepo/charts/charts` (raw PUT) | **404** (Harbor core 라우터에 PUT 없음, HTML 404 페이지) |
| 같은 raw PUT, 끝에 `/` | 404 |
| `curl -T … /chartrepo/charts/` (raw PUT) | 404 |
| `-X PUT -H 'Content-Type: application/octet-stream' --data-binary` | 404 |
| `-X POST --data-binary @x.tgz` (curl 기본 CT = application/x-www-form-urlencoded) | **500** (beego Internal Server Error — core 가 폼 파싱 시도) |
| `-X POST -H 'Content-Type: application/octet-stream' --data-binary @h27a-0.3.0.tgz` | **201** → index 에 등장, 재다운로드 sha256 `369ad660…` = 원본 **MATCH** |

→ **결론: Harbor 2.7 chart 업로드는 raw PUT 을 받지 않는다(404). 그러나 raw body 를 `POST` + `Content-Type: application/octet-stream` 으로 보내면 받는다(201).** ChartMuseum 원래 API 가 `curl --data-binary "@mychart-0.1.0.tgz" http://…/api/charts` 를 지원하고(ChartMuseum README "Uploading a Chart Package"), Harbor core 의 chartrepo 프록시가 이를 그대로 넘기기 때문. 단 Content-Type 이 form-urlencoded 이면 core 가 500.

index.yaml urls 형식 (`GET /chartrepo/charts/index.yaml`, absoluteUrl=false):
```
  h27b:
  - apiVersion: v2
    digest: 91c49c4c0be4fea70518b15b1f4c57543512818ed3f75098f9c13aa6f188d515
    name: h27b
    urls:
    - charts/h27b-1.0.0.tgz
    version: 1.0.0
```
→ **상대 URL `charts/<name>-<ver>.tgz`**. helm 은 repo URL 기준으로 해석 → 엔드포인트에선 `/repository/helm-hosted/charts/<f>.tgz` 로 요청이 온다 (3단계에서 매핑 필요).

다운로드 sha256 (`GET /chartrepo/charts/charts/<f>.tgz`, 인증):
```
h27a-0.1.0 orig=3cd411a5dac3c10a got=3cd411a5dac3c10a MATCH
h27a-0.2.0 orig=c640ff30489e8b22 got=c640ff30489e8b22 MATCH
h27b-1.0.0 orig=91c49c4c0be4fea7 got=91c49c4c0be4fea7 MATCH
h27a-0.3.0 (octet-stream POST) MATCH 369ad660ef490fe7…
```

helm 클라이언트 (격리 HELM_* 환경):
```
$ helm repo add h27 http://172.16.141.11:30003/chartrepo/charts --username ci-helm --password "$CIPW"   → added
$ helm repo update h27 → Successfully got an update
$ helm search repo h27/ --versions
h27/h27a 0.3.0 / 0.2.0 / 0.1.0,  h27/h27b 1.0.0
$ helm pull h27/h27b --version 1.0.0; helm pull h27/h27a --version 0.3.0
91c49c4c…d515 (=원본), 369ad660…20da (=원본)
```

무인증 접근:

| 요청 | project private | project public |
|---|---|---|
| GET /chartrepo/charts/index.yaml | 401 | 200 |
| GET /chartrepo/charts/charts/h27b-1.0.0.tgz | 401 | 200 |
| GET /api/chartrepo/charts/charts (목록 API) | 401 | 200 |
| GET 없는 차트 nope-9.9.9.tgz | – | 404 |
| POST -F (무인증) | 401 `{"errors":[{"code":"UNAUTHORIZED"…}]}` | 401 |
| POST octet-stream (무인증) | – | 401 |
| POST -F 틀린 비번 | 401 | – |
| DELETE /api/chartrepo/charts/charts/h27b/1.0.0 (무인증) | – | 401 |

- 주의: Harbor 401 응답에 **`WWW-Authenticate` 헤더가 없다** (`curl -D -` 확인). helm/curl 은 `--username`/`-u` 시 선제 Basic 을 보내므로 동작엔 문제 없음. 챌린지를 기다리는 클라이언트(일부 브라우저/툴)는 비번을 안 보낼 수 있다.
- 이후 시험을 위해 project charts 는 **public** 으로 둠 (`PUT /api/v2.0/projects/charts {"metadata":{"public":"true"}}` → 200). 읽기 무인증 / 쓰기 인증 = Nexus helm-hosted(anonymous read) 와 같은 모양.

## 3. 엔드포인트 nginx 치환 (2026-10-07 22:14~22:26 KST)
### 3-1. 판단
- nexus-endpoint 이미지 `docker.io/library/nginx:1.27-alpine` 에 `nginx-module-njs-1.27.5.0.8.10-r1` 이 이미 들어 있음 → `load_module /etc/nginx/modules/ngx_http_js_module.so;` 만 추가. **컨테이너 재생성 안 함** (같은 inode 242449221 로 `cat new > nginx.conf` 덮어쓰기 + `nginx -t && nginx -s reload`)
- njs 스크립트 위치: `~/nexus-lab/harbor/endpoint/active/helm_put.js` (컨테이너 `/etc/nginx/active/helm_put.js`, 기존 RW 바인드 마운트)
- helm location 은 **19000(pull)·19001(push) 두 server 모두**에 있음(기존 변환기판과 같은 구조) → 둘 다 Harbor 2.7 로 치환
- **docker 분기(dlops → Harbor)는 Harbor 2.13(30002) 그대로 둠.** helm 만 Harbor 2.7(30003, upstream `harbor27`). 확인: `curl http://127.0.0.1:19000/v2/dlops/app2/tags/list` → 401(Harbor 2.13 토큰 챌린지, 기존과 동일)
- 매핑:

| 클라이언트 요청 (엔드포인트) | nginx 처리 | Harbor 2.7 |
|---|---|---|
| GET/HEAD /repository/helm-hosted/index.yaml | rewrite … break | GET /chartrepo/charts/index.yaml |
| GET/HEAD /repository/helm-hosted/charts/<f> (index 의 상대 url) | rewrite … break | GET /chartrepo/charts/charts/<f> |
| GET/HEAD /repository/helm-hosted/<f>.tgz (Nexus 식 직접 경로) | rewrite … break | GET /chartrepo/charts/charts/<f>.tgz |
| PUT/POST /repository/helm-hosted/<f>.tgz (`curl -T x.tgz …/helm-hosted/`) | rewrite → internal `/_h27_upload` → njs `helm_put.put` | multipart POST /api/chartrepo/charts/charts (field `chart`, filename=<f>) |
| 그 외 메서드 (DELETE 등) | 405 | – |
| 그 외 경로 (/repository/helm-hosted/foo) | 404 (nginx) | – |

### 3-2. 적용 중 발견·수정 (원인 좁힌 과정)
1. **첫 적용(22:14:50)**: `nginx -t` OK, reload → T1 index 200, `curl -u ci-helm -T h27a-0.4.0.tgz …/helm-hosted/` → **201 {"saved":true}** (access.log `PUT /repository/helm-hosted/h27a-0.4.0.tgz status=201 rt=0.007`). njs 변환이 첫 시도에 동작
2. **빈 본문 PUT → 500**: error.log `at put (/etc/nginx/active/helm_put.js:28)` = `Buffer.concat` 행. `r.requestBuffer` 가 길이 0 일 때 걸림 → `body.length === 0` 이면 400 `{"error":"empty body"}` 로 처리. 재시험 400
3. **30MB·60MB 업로드 → 502 `TypeError: detached buffer`**:
   - 처음엔 njs 대용량 버퍼 문제로 의심. 그러나 같은 30MB 를 **Mac 에서 Harbor 로 직접 -F** 해도 502 → njs 아님
   - chartmuseum 로그: `"path":"/api/charts/charts","comment":"Error #01: HTTP request too large\n","statusCode":413`, core 로그 `reverseproxy.go:503: http: proxy error: write … connection reset by peer` → chartmuseum 이 413 으로 끊고 core 가 502 로 바꿈
   - 한도: `kubectl -n harbor27 get cm -o yaml` → `MAX_UPLOAD_SIZE: "20971520"`. chart 1.11.0 `templates/chartmuseum/chartmuseum-cm.yaml:41` 에 **하드코딩**(values 키 없음)
   - "detached buffer" 는 Harbor 502 의 **빈 응답 본문**을 `Buffer.from(빈 ArrayBuffer)` 할 때 njs 0.8.10 이 내는 에러 → 본문 길이 0 이면 `''` 반환으로 수정
   - nginx helm location 의 `client_max_body_size` 를 **20m** 으로 (Harbor 한도와 일치, 초과는 nginx 가 즉시 413). `client_body_buffer_size 64m` 은 그대로(≥ max 이므로 본문 전체가 메모리 → `r.requestBuffer`)
   - 재시험: big19(19,931,957B) 201 + 재다운로드 MATCH, big30 413, 70MB 413, 직접 Harbor -F big30 은 413(이번엔 502 아님 — reset 경쟁에 따라 413/502 가 갈림)
4. **대용량 업로드가 엔드포인트 경유 시 느림** (big10 3.9s, big19 9.0s vs Mac→Harbor 직접 -F 0.22s/0.49s):
   - Harbor nginx 로그에서 njs fetch POST 의 request_time 이 3.83s/8.81s → 송신 쪽이 느림
   - `js_fetch_buffer_size 1m` 시도 → big19 10.3s 로 개선 없음 → 되돌림
   - **컨테이너 안에서 curl 로 직접 Harbor 에 octet POST**: `container→Harbor octet POST [201] 9.107s up=2188528B/s`, `-F 9.66s` → **podman 컨테이너 → VMware VM(172.16.141.11) 경로 자체가 ~2.2MB/s**. njs 가 아니라 랩 네트워크 경로 한계 (운영 토폴로지와 무관)
   - 참고로 njs 없는 대안(아래 3-4 B안)은 스트리밍이라 big19 3.55s (수신·송신이 겹침)
5. **HEAD 404**: `curl -I` 로 Harbor 직접 `HEAD /chartrepo/charts/index.yaml` → 404, `HEAD …/charts/h27b-1.0.0.tgz` → 404 (Harbor 2.7 core 가 GET 만 라우팅). helm 은 HEAD 를 안 쓰지만 모니터링·스크립트용으로 `map $request_method $h27_method {HEAD GET;}` + `proxy_method $h27_method` → HEAD index/tgz 200, 없는 차트 404. (reload 직후 1회 404 는 구 워커가 받은 것, 이후 12/12 200)
6. 부하 시 upstream 연결 문제 → 4단계 부하 절에서 `keepalive 256`, `proxy_connect_timeout 3s`, 같은 server 2줄 + `proxy_next_upstream` 로 GET 1회 재시도 추가

### 3-3. Harbor 2.7 업로드 경로 비교 실험 (njs 없이 가능한가)
- 2단계에서 Harbor 가 **raw body POST + `Content-Type: application/octet-stream`** 을 받는 것을 확인 → njs 없이 `proxy_method POST` + `proxy_set_header Content-Type application/octet-stream` + `rewrite ^ /api/chartrepo/charts/charts break` 만으로도 될지 임시 location `/repository/helm-hosted-b/` 로 시험 (설정: logs/harbor27/nginx.conf.optB-test, 시험 후 제거 — 최종 nginx.conf 에 `helm-hosted-b` 0건)

| 시험 | A안 njs multipart (최종 채택) | B안 proxy_method POST (njs 없음) |
|---|---|---|
| PUT 정상 | 201 | 201 (h27b-1.0.1, 재다운로드 MATCH) |
| 무인증 / 틀린 비번 | 401 / 401 | 401 / 401 |
| 깨진 tgz | 400 `{"error":"gzip: invalid header"}` | 400 (같은 본문) |
| big19 (19.9MB) | 201, 9.0s | 201, 3.55s |
| big30 | 413 (nginx) | 413 (nginx) |
| 동시 20 업로드 | 20×201, max 0.14s, index 20/20, sha 20/20 | 20×201, max 0.07s, index 20/20, sha 20/20 |
| 파일명 | multipart filename 으로 전달 | 파일명 미전달 (chartmuseum 은 tgz 안의 Chart.yaml 로 이름·버전 결정 → 결과 동일) |
| 의존 | njs 모듈, 본문 메모리 버퍼(요청당 최대 20MB) | Harbor core 가 비-multipart 를 chartmuseum 에 그대로 넘기는 동작(문서화된 Harbor API 아님, ChartMuseum API 의 `--data-binary` 업로드에 기댐) |

→ 둘 다 동작. 최종은 지시대로 **A안(njs)** 을 남김. A안은 Harbor 의 공식 업로드 형식(multipart `chart` 필드, Harbor UI·`helm cm-push` 와 같은 형식)만 쓰므로 Harbor 쪽 비공식 동작에 기대지 않음. B안은 더 단순하고 스트리밍(메모리 사용 적음)이지만 Harbor core 의 비-multipart 처리에 기댐(Content-Type 이 form-urlencoded 면 500 인 것처럼 경계가 미묘).

## 4. 엔드포인트 경유 시험 (2026-10-07 22:15~22:30 KST)
- 스크립트 logs/harbor27/test-ep.sh (PORT·NEW 환경변수), 원본 출력 test-ep-19000.txt / test-ep-19001.txt(첫 적용), test-ep-final-*.txt / test-ep-final2-19000.txt(최종 설정)
- helm location 은 19000·19001 양쪽. 표는 최종 설정 기준(19000), 19001 도 같은 결과

### 4-1. 기능 (T1~T7)

| # | 시험 | 결과 | 근거 |
|---|---|---|---|
| T1 | GET http://127.0.0.1:19000/repository/helm-hosted/index.yaml | **PASS** 200, application/x-yaml, urls 상대 `charts/<f>` | `T1 GET index.yaml: 200 22066B application/x-yaml` |
| T2 | `helm repo add ep http://127.0.0.1:19000/repository/helm-hosted/` (무인증) + update + search | **PASS** 업로드한 전 버전 표시 (72 versions), 인증 repo add 도 동일 | `T2 repo add (무인증): OK`, `Successfully got an update`, `T2b … 72 versions` |
| T3 | helm pull sha256 = 원본 | **PASS** 3/3 + 직접경로 `<f>.tgz` GET 도 MATCH | `T3 helm pull h27a-0.1.0: 3cd411a5… MATCH` 등 |
| T4 | `curl -u ci-helm -T h27a-0.4.x.tgz http://127.0.0.1:19000/repository/helm-hosted/` | **PASS** 201 `{"saved":true}`, index 반영 **57~62ms(폴링 1회 = 즉시)**, helm repo update/search 에 보임, 재다운로드 sha256 MATCH (19000·19001 각각) | `T4 … → 201`, `T4 index 반영 지연: 60ms (폴링 1회)`, `T4 재다운로드 sha256: … MATCH` |
| T5 | 무인증 PUT / 틀린 비번 PUT | **PASS** 401 / 401 (본문 Harbor 그대로 `{"errors":[{"code":"UNAUTHORIZED","message":"UnAuthorized"}]}`), 새 버전 h27c-9.9.9 로 확인 시 index 0건·GET 404 | `무인증 PUT h27c-9.9.9: 401 틀린비번: 401 index 에 h27c-9.9.9: 0건 GET: 404` (스크립트의 h27c-2.0.1 "1건" 은 그 전에 동시 업로드 시험에서 정상 업로드된 버전이라 무관) |
| T5b | DELETE (인증) | 405 (nginx 에서 차단. Nexus 경로로 삭제 기능 미제공) | `T5 DELETE(인증): 405` |
| T6 | 없는 차트 | **PASS** `charts/nope-9.9.9.tgz` 404, `nope-9.9.9.tgz` 404, `helm pull ep/nope` → `not found in ep index`, 엉뚱한 경로 404 | test-ep-final*.txt |
| T7 | index.yaml 연속 20회 | **PASS** 5.3~9.5ms (중앙 ≈5.6ms) | `T7 … 5.6 5.6 7.8 5.5 …` |
| 추가 | 중복 버전 재업로드 | 201 (덮어쓰기) — Nexus "Disable redeploy" 정책이면 400 이었을 것 → **동작 차이** | `중복 업로드 h27a-0.4.0: {"saved":true} [201]` |
| 추가 | 깨진 tgz / 빈 본문 | 400 `gzip: invalid header` / 400 `empty body` | |
| 추가 | 19.9MB / 30MB / 70MB | 201(MATCH) / 413 / 413 | Harbor chartmuseum 한도 20MiB |
| 추가 | HEAD index·tgz | 200 (HEAD→GET 변환 후. Harbor 직접은 404) | |
| 추가 | 동시 업로드 20 (njs) | **PASS** 20×201, max 0.13~0.14s, index 20/20, sha256 20/20 (2회: h27c-2.0.x, h27c-4.0.x) | conc-njs.txt, conc-njs-final.txt |

### 4-2. 부하 (oha -n 2000 -c 200, logs/harbor27/load.sh → oha-*.json, load-1.txt·load-2.txt·load-final.txt)

| 설정 단계 | 대상 | 2xx 성공률 | rps | p50 | p95 | p99 | 비고 |
|---|---|---|---|---|---|---|---|
| 첫 적용 (keepalive 32) | ep index.yaml | 100% | 275 | 176ms | 1244ms | 5191ms | |
| 〃 | ep tgz | 100% | 101 | 174ms | 627ms | 11256ms | |
| 〃 2회차 | ep index / tgz | 100% / 100% | 103 / 277 | 180 / 180ms | 324 / 546ms | 11248 / 4154ms | nginx rt p99 7.2s → 지연은 nginx→Harbor 구간 |
| 기준선 | ep 로컬 404 (nginx 자체 응답) | – | ~5000 | 9ms | ~370ms | ~390ms | podman 포트포워딩 자체 비용 |
| 〃 | -c 32 index | 100% | 643 | 48ms | 72ms | 88ms | 동시성 ≤ keepalive 면 매끈 → 새 upstream 연결이 원인 |
| keepalive 256 직후(콜드) | ep index | 99.8% | 33 | 169ms | 292ms | 19377ms | 504×1(connect 60s timeout), 클라 측 연결 끊김×4 |
| keepalive 256 웜 ×3 | ep index | 100% | 666~689 | 284~291ms | 340~384ms | 409~427ms | |
| 〃 | ep tgz | 100% | 525~550 | 277~320ms | 822~1106ms | 1004~1623ms | |
| + connect_timeout 3s 콜드 | ep index | 99.0% | 660 | 241ms | 317ms | 2332ms | 504×15 (3s 에 포기) |
| + 재시도(server 2줄, next_upstream) 콜드 | ep index | 99.7% | 638 | 270ms | 375ms | 2365ms | **nginx 측 2000/2000=200**, 실패 6건은 클라이언트↔podman 포트포워딩 'connection closed' |
| 〃 웜 | ep index / tgz | 100% / 100% | 681 / 561 | 282 / 312ms | 402 / 636ms | 432 / 1061ms | |
| **최종 설정** 1회차 | ep index / tgz | **100% / 100%** | 601 / 615 | 164 / 283ms | 2205 / 516ms | 3298 / 1142ms | keepalive 유휴 만료 뒤 첫 버스트 |
| **최종 설정** 2회차 | ep index / tgz | **100% / 100%** | 564 / 572 | 353 / 322ms | 409 / 653ms | 443 / 887ms | |
| 비교: Mac→Harbor 직접 | index / tgz | 100% / 100% | 719~809 / 623~702 | 237~268 / 239~268ms | 301~329 / 435~676ms | 338~389 / 787~1077ms | |

- 동시 업로드 20: 위 4-1 (njs 20×201, B안 20×201)
- 해석: Harbor 2.7 chartmuseum 자체는 200 동시에서 100% 성공(직접). 엔드포인트 경유 꼬리 지연·콜드 실패는 **podman 컨테이너 → VMware VM 네트워크 경로**(새 TCP 연결 SYN 유실, 업로드 2.2MB/s)에서 생김 — 3-2 의 4번 진단과 같은 경로. 운영(엔드포인트와 Harbor 가 같은 LAN)에서는 재현 조건이 다름. 완화책으로 upstream keepalive 256 + connect 3s + GET 1회 재시도를 최종 설정에 넣음

## 5. 결론 (2026-10-07 22:32 KST)
### (a) 변환기 없이 Nexus helm 경로 유지가 되는가 → **된다 (랩 기준)**
- Harbor 2.7.0 + 내장 ChartMuseum + 엔드포인트 nginx(njs 0.8.10, 기존 nginx:1.27-alpine 이미지 그대로)만으로 `/repository/helm-hosted/` 의 **읽기(index.yaml·charts/<f>·<f>.tgz)와 Nexus 식 업로드(`curl -u user -T x.tgz …/helm-hosted/`)** 를 모두 유지. Python helm 변환기(helm-adapter ×2)는 경로에서 빠짐(컨테이너는 stop 하지 않고 그대로 둠 — 트래픽만 안 감)
- CI 명령 변경 불필요: T4(201 + 즉시 반영 + sha 일치), T5(401), 동시 20 업로드 모두 PASS
- 읽기는 순수 rewrite(ChartMuseum index 의 상대 URL `charts/<f>` 덕분), 업로드는 njs 40줄. 변환기판의 index 재생성·OCI 변환·레플리카 간 무효화 같은 상태가 사라지고 index 반영이 즉시(~60ms)

### (b) 안 되거나 다른 부분과 이유
1. **업로드 한도 20MiB**: chart 1.11.0 이 chartmuseum `MAX_UPLOAD_SIZE: "20971520"` 을 하드코딩(templates/chartmuseum/chartmuseum-cm.yaml:41, values 키 없음). 더 큰 차트는 ConfigMap 직접 패치(helm upgrade 시 원복됨) 또는 post-renderer 필요. 엔드포인트는 20m 으로 맞춰 413
2. **같은 버전 재업로드가 덮어써짐(201)**: Harbor chartmuseum 은 overwrite 허용. Nexus hosted 의 "Disable redeploy" 를 쓰고 있었다면 동작이 다름(불변성 상실)
3. **DELETE·Nexus REST(/service/rest/v1/components 등) 미지원**: 엔드포인트는 405. 삭제는 Harbor API `DELETE /api/chartrepo/charts/charts/<name>/<ver>` 로 해야 함
4. **Harbor 401 에 WWW-Authenticate 헤더 없음**: helm/curl 처럼 선제 Basic 을 보내는 클라이언트는 문제없지만, 챌린지를 기다렸다 인증하는 클라이언트는 private 프로젝트에서 실패할 수 있음 (랩은 project public 이라 읽기 무인증)
5. **HEAD 미지원(Harbor 직접 404)** → nginx 에서 HEAD→GET 으로 우회
6. **njs 는 본문을 메모리에 통째로 버퍼링** (요청당 최대 20MiB). 동시 대용량 업로드 시 엔드포인트 메모리 = 동시수 × 20MiB. 대안 B안(proxy_method POST + octet-stream)은 스트리밍이지만 Harbor 의 비공식 동작에 기댐(3-3)
7. 랩 한정: 엔드포인트(podman)→클러스터(VMware) 경로 업로드 2.2MB/s, 새 연결 버스트 시 SYN 유실 → 큰 차트 업로드 느림·콜드 부하 꼬리. Harbor·njs 문제가 아님(컨테이너 안 curl 로 동일 재현)

### (c) 운영 적용 시 주의
- **Harbor 2.7 은 EOL 계열**: Harbor 는 최신 3개 마이너만 패치. 2.8 에서 ChartMuseum 제거(2.6 deprecated)라 2.7.x 가 마지막 ChartMuseum 계열이고 보안 패치가 더 나오지 않음. 이번 랩은 2.7.0(최종 2.7.4 아님 — octohelm 미러에 v2.7.0 을 확인해 사용). 운영에 쓴다면 최소 2.7.4 확인·외부 노출 금지(폐쇄망·엔드포인트 뒤)·기간 한정(Nexus Pro 복귀까지)
- **ChartMuseum 유지보수 모드**: 신규 기능·적극적 보안 대응 기대 불가. ghcr.io/octohelm 이미지는 커뮤니티 재빌드(arm64) — 운영 amd64 라면 공식 goharbor 이미지 사용
- **OCI 로의 전환 비용 기록**: 이 구성은 차트를 chartmuseum 저장소(PVC harbor27-chartmuseum)에 둔다. 나중에 Harbor 최신으로 올리면 chartmuseum 데이터는 OCI 로 마이그레이션해야 함
- **보안**: 업로드 계정은 project developer(ci-helm), admin 사용 금지. 401 본문은 Harbor JSON 그대로 노출됨
- **업로드 한도·덮어쓰기 정책**을 CI 측과 합의(20MiB, 동일 버전 재업로드 금지 규칙을 CI 에서)
- 엔드포인트 nginx: `load_module` 을 추가했으므로 njs 없는 nginx 이미지로 바꾸면 기동 실패. 업스트림 keepalive·connect timeout·GET 재시도는 운영 네트워크에서 다시 조정
- **내년 Nexus Pro 복귀 시 되돌리기**: 엔드포인트 helm location 을 Nexus(nx_pull/nx_push)의 `/repository/helm-hosted/` 로 다시 proxy_pass 하면 클라이언트 URL 은 그대로. 데이터는 Harbor 2.7 에서 전 차트 다운로드(`GET /api/chartrepo/charts/charts` 로 목록 → `GET /chartrepo/charts/charts/<f>`) 후 Nexus 에 `curl -T` 로 재업로드(Nexus 식 업로드라 스크립트 단순, sha256 대조). 복귀 중 업로드 동결 필요

### (d-1) 최종 nginx 설정 전문 (~/nexus-lab/harbor/endpoint/nginx.conf = logs/harbor27/nginx.conf.h27, inode 242449221 유지)
```nginx
# 같은 엔드포인트에서 경로별 분기: 커스텀 이미지(dlops/…) → Harbor, 나머지 → Nexus
# [k8s 판] docker dlops upstream = Harbor 2.13 (172.16.141.11:30002 NodePort, ns harbor) — 그대로 유지
# [Harbor 2.7 helm 판] /repository/helm-hosted/ → Harbor 2.7.0 ChartMuseum (172.16.141.11:30003, ns harbor27, project charts)
#   - 읽기(GET/HEAD): nginx rewrite 만으로 경로 치환 (변환기 없음)
#   - 업로드(PUT/POST raw body, Nexus 식 curl -T): njs(helm_put.js) 가 multipart/form-data(field chart) 로 바꿔 POST /api/chartrepo/charts/charts
#   - 되돌리기: logs/harbor27/progress.md "되돌리기" 절 (helm 변환기판 = logs/harbor27/nginx.conf.before)
# 토큰: 클라이언트는 Nexus 안내대로 /v2/token 에 요청하지만, scope 가 dlops/ 면 Harbor /service/token 으로 넘겨 Harbor 토큰을 받게 한다
load_module /etc/nginx/modules/ngx_http_js_module.so;
worker_processes 1;
error_log /var/log/nginx/error.log warn;
events { worker_connections 4096; }
http {
    log_format reg '$time_iso8601 $remote_addr "$request" status=$status upstream=$upstream_addr ustatus=$upstream_status rt=$request_time';
    access_log /var/log/nginx/access.log reg;
    client_max_body_size 0;
    js_import helm_put from /etc/nginx/active/helm_put.js;   # RW 마운트 harbor/endpoint/active/helm_put.js
    js_fetch_timeout 120s;
    upstream nx_pull { server 10.89.200.14:5000; }
    upstream nx_push { server 10.89.200.14:5001; }
    upstream harbor  { server 172.16.141.11:30002; }   # 클러스터 Harbor 2.13 (docker dlops 분기)
    upstream harbor27 {                                # 클러스터 Harbor 2.7.0 + ChartMuseum (helm 분기)
        server 172.16.141.11:30003 max_fails=0;
        server 172.16.141.11:30003 max_fails=0;        # 같은 주소 2번 = GET 의 connect 실패를 1회 재시도하기 위함 (단일 server 면 proxy_next_upstream 이 재시도 대상 없음)
        keepalive 256;                                 # 32 이면 -c 200 에서 새 연결이 podman→VM 경로로 몰려 p99 3~11s (progress 4단계)
    }
    # Harbor 2.7 chartrepo 는 HEAD 를 404 로 답한다(직접 curl -I 확인) → helm 경로 HEAD 는 GET 으로 보내고 본문은 nginx 가 버린다
    map $request_method $h27_method {
        HEAD    GET;
        default $request_method;
    }
    # 커스텀 이미지 접두사 목록 (scope 는 URL 인코딩된 채로 옴: repository%3Adlops%2F...)
    map $arg_scope $tok_dst {
        default nexus;
        "~^repository(:|%3A)dlops(/|%2F)" harbor;
    }
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;

    server {
        listen 19000;
        location /service/ { proxy_pass http://harbor; }
        location = /v2/token {
            if ($tok_dst = harbor) { rewrite ^ /_hb_token last; }
            proxy_pass http://nx_pull;
        }
        location = /_hb_token { internal; set $args "scope=$arg_scope&service=harbor-registry"; proxy_pass http://harbor/service/token; }
        location ~ ^/v2/dlops/ { proxy_pass http://harbor; }
        location /repository/helm-hosted/ {   # 기존 Nexus helm 경로 유지 → Harbor 2.7 chartrepo
            client_max_body_size 20m;                         # = Harbor 2.7 chartmuseum MAX_UPLOAD_SIZE 20971520 (chart 1.11.0 하드코딩). 초과는 nginx 413
            if ($request_method ~ ^(PUT|POST)$) { rewrite ^ /_h27_upload last; }   # Nexus 식 업로드 → njs
            if ($request_method !~ ^(GET|HEAD)$) { return 405; }
            rewrite ^/repository/helm-hosted/index\.yaml$      /chartrepo/charts/index.yaml  break;
            rewrite ^/repository/helm-hosted/charts/([^/]+)$   /chartrepo/charts/charts/$1   break;   # index 의 상대 url charts/<f>
            rewrite ^/repository/helm-hosted/([^/]+\.tgz)$     /chartrepo/charts/charts/$1   break;   # Nexus 식 직접 경로 <f>.tgz
            return 404;
            proxy_pass http://harbor27;
            proxy_method $h27_method;
            proxy_connect_timeout 3s;                         # 콜드 부하 시 podman→VM 경로 SYN 유실로 60s 대기 후 504 를 본 적 있음 (progress 4단계)
            proxy_next_upstream error timeout http_502 http_503 http_504;   # GET/HEAD 만 여기로 옴(업로드는 njs) → 재시도 안전
            proxy_next_upstream_tries 2;
            proxy_set_header Connection "";                   # upstream keepalive (location 에서 set_header 하면 상속이 끊겨 아래를 다시 적음)
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
        location = /_h27_upload {
            internal;
            client_max_body_size 20m;                         # = Harbor 2.7 chartmuseum MAX_UPLOAD_SIZE 20971520 (chart 1.11.0 하드코딩). 초과는 nginx 413
            client_body_buffer_size 64m;                      # 본문 전체를 메모리에 → njs r.requestBuffer
            set $h27_upload_url http://172.16.141.11:30003/api/chartrepo/charts/charts;
            js_content helm_put.put;
        }
        location / { proxy_pass http://nx_pull; }
    }
    server {
        listen 19001;
        location /service/ { proxy_pass http://harbor; }
        location = /v2/token {
            if ($tok_dst = harbor) { rewrite ^ /_hb_token last; }
            proxy_pass http://nx_push;
        }
        location = /_hb_token { internal; set $args "scope=$arg_scope&service=harbor-registry"; proxy_pass http://harbor/service/token; }
        location ~ ^/v2/dlops/ { proxy_pass http://harbor; }
        location /repository/helm-hosted/ {   # 기존 Nexus helm 경로 유지 → Harbor 2.7 chartrepo
            client_max_body_size 20m;                         # = Harbor 2.7 chartmuseum MAX_UPLOAD_SIZE 20971520 (chart 1.11.0 하드코딩). 초과는 nginx 413
            if ($request_method ~ ^(PUT|POST)$) { rewrite ^ /_h27_upload last; }   # Nexus 식 업로드 → njs
            if ($request_method !~ ^(GET|HEAD)$) { return 405; }
            rewrite ^/repository/helm-hosted/index\.yaml$      /chartrepo/charts/index.yaml  break;
            rewrite ^/repository/helm-hosted/charts/([^/]+)$   /chartrepo/charts/charts/$1   break;
            rewrite ^/repository/helm-hosted/([^/]+\.tgz)$     /chartrepo/charts/charts/$1   break;
            return 404;
            proxy_pass http://harbor27;
            proxy_method $h27_method;
            proxy_connect_timeout 3s;                         # 콜드 부하 시 podman→VM 경로 SYN 유실로 60s 대기 후 504 를 본 적 있음 (progress 4단계)
            proxy_next_upstream error timeout http_502 http_503 http_504;   # GET/HEAD 만 여기로 옴(업로드는 njs) → 재시도 안전
            proxy_next_upstream_tries 2;
            proxy_set_header Connection "";
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
        location = /_h27_upload {
            internal;
            client_max_body_size 20m;                         # = Harbor 2.7 chartmuseum MAX_UPLOAD_SIZE 20971520 (chart 1.11.0 하드코딩). 초과는 nginx 413
            client_body_buffer_size 64m;
            set $h27_upload_url http://172.16.141.11:30003/api/chartrepo/charts/charts;
            js_content helm_put.put;
        }
        location / { proxy_pass http://nx_push; }
    }
}
```

### (d-2) njs 스크립트 전문 (~/nexus-lab/harbor/endpoint/active/helm_put.js → 컨테이너 /etc/nginx/active/helm_put.js)
```javascript
// Nexus 식 helm 업로드(raw body PUT/POST /repository/helm-hosted/<file>.tgz)를
// Harbor 2.7 ChartMuseum 업로드(multipart POST /api/chartrepo/<project>/charts, field "chart")로 바꾼다.
// - 본문은 r.requestBuffer 로 메모리에서 통째로 읽는다(nginx: client_body_buffer_size = client_max_body_size = 64m)
// - Authorization 헤더는 그대로 넘기고, Harbor 응답 코드·본문·Content-Type 을 그대로 돌려준다
// - 대상은 nginx 변수 $h27_upload_url (nginx.conf 에서 set)
function put(r) {
    var body = r.requestBuffer;
    if (body === undefined || body === null || body.length === 0) {
        // 본문이 임시파일로 넘어간 경우(버퍼보다 큼) 또는 본문 없음
        var len = parseInt(r.headersIn['Content-Length'] || '0', 10);
        r.headersOut['Content-Type'] = 'application/json';
        r.return(len > 0 ? 413 : 400, JSON.stringify({error: len > 0 ? 'body not buffered in memory (too large)' : 'empty body'}) + '\n');
        return;
    }
    // 파일명: 원래 요청 URI 의 마지막 세그먼트 (curl -T x.tgz http://ep/repository/helm-hosted/ → .../x.tgz)
    var path = r.variables.request_uri.split('?')[0];
    var seg = path.substring(path.lastIndexOf('/') + 1);
    var fname;
    try { fname = decodeURIComponent(seg); } catch (e) { fname = seg; }
    if (!fname) { fname = 'upload.tgz'; }
    fname = fname.replace(/["\r\n\\]/g, '_');

    var boundary = '----njsHelmPut' + Date.now().toString(16) + Math.floor(Math.random() * 0xffffffff).toString(16);
    var head = Buffer.from('--' + boundary + '\r\n' +
        'Content-Disposition: form-data; name="chart"; filename="' + fname + '"\r\n' +
        'Content-Type: application/octet-stream\r\n\r\n');
    var tail = Buffer.from('\r\n--' + boundary + '--\r\n');
    var payload = Buffer.concat([head, body, tail]);

    var headers = {'Content-Type': 'multipart/form-data; boundary=' + boundary};
    if (r.headersIn['Authorization']) { headers['Authorization'] = r.headersIn['Authorization']; }

    ngx.fetch(r.variables.h27_upload_url, {method: 'POST', headers: headers, body: payload})
        .then(function (res) {
            return res.arrayBuffer().then(function (ab) {
                var ct = res.headers.get('Content-Type');
                if (ct) { r.headersOut['Content-Type'] = ct; }
                // 본문 없는 응답(예: Harbor 502)에서 Buffer.from(빈 ArrayBuffer) 는 njs 0.8.10 에서 "detached buffer" → 빈 문자열로
                r.return(res.status, ab.byteLength > 0 ? Buffer.from(ab) : '');
            });
        })
        .catch(function (e) {
            r.error('helm_put: upstream fetch failed: ' + e);
            r.headersOut['Content-Type'] = 'application/json';
            r.return(502, JSON.stringify({error: 'upstream fetch failed', detail: String(e)}) + '\n');
        });
}

export default {put};
```

## 6. 현재 상태와 되돌리기
- 현재: 엔드포인트 helm 경로 = Harbor 2.7(30003) + njs. docker dlops 분기 = Harbor 2.13(30002). helm-adapter / helm-adapter-2 컨테이너는 **Running 그대로**(stop 안 함). ns harbor(2.13) **scale 변경 없음**. ns harbor27 8 pod Running
- 되돌리기(엔드포인트를 helm 변환기판으로) — 백업본은 `nginx -t -c` 로 미리 문법 확인함(`_revert_test.conf … test is successful`):
```bash
cat ~/nexus-lab/logs/harbor27/nginx.conf.before > ~/nexus-lab/harbor/endpoint/nginx.conf   # 같은 inode 로 덮어쓰기 (mv 금지)
podman exec nexus-endpoint nginx -t && podman exec nexus-endpoint nginx -s reload
# load_module 제거가 reload 로 반영 안 되면: podman restart nexus-endpoint
# (선택) njs 스크립트 제거: rm ~/nexus-lab/harbor/endpoint/active/helm_put.js
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19000/repository/helm-hosted/index.yaml   # access.log upstream=10.89.200.32/33:8080 확인
```
- (선택) Harbor 2.7 제거: `helm uninstall harbor27 -n harbor27` → PVC 는 resourcePolicy keep 이라 남음 → `kubectl delete ns harbor27` 로 PVC 까지 삭제. 레지스트리 미러의 octohelm/harbor/*:v2.7.0 이미지는 남음
- 시험 데이터: Harbor 2.7 project `charts` 에 h27a/h27b/h27c/big10/big19 등 시험 차트, 사용자 ci-helm(비번은 세션 scratchpad h27.ci 에만). 시험 데이터라 실제 할 일로 승격하지 않음
- helm 격리 홈 logs/harbor27/helmhome: 인증 repo(epauth, h27)는 `helm repo remove` 로 제거, 남은 repo(ep, harbor)는 비번 없음

## 산출물
- logs/harbor27/: progress.md, values.yaml, install.log, image-seed.log, nginx.conf.before(원본 백업), nginx.conf.h27(최종), nginx.conf.optB-test(B안 임시), helm_put.js.copy, test-ep.sh, test-ep-*.txt, load.sh, load-*.txt, oha-*.json, conc-*.txt, index-direct.yaml, index-ep.yaml, charts/(시험 차트), pull-*/

## 2026-10-07 23:0x 6. 업로드 한도 20MiB → 100MiB 로 올리기 (사용자 질문 "늘릴 수 있나")
- `kubectl -n harbor27 patch cm harbor27-chartmuseum --type merge -p '{"data":{"MAX_UPLOAD_SIZE":"104857600"}}'` + `rollout restart deploy/harbor27-chartmuseum` → pod env MAX_UPLOAD_SIZE=104857600 확인
- 엔드포인트 nginx: client_max_body_size 20m→100m, client_body_buffer_size 64m→128m (njs 가 본문을 메모리에 올리므로 buffer ≥ max_body). 백업 logs/harbor27/nginx.conf.h27-20m
  - 주의: sed -i 로 파일을 바꿔 inode 가 달라져 컨테이너가 설정을 못 봄(nginx -t "No such file") → podman restart nexus-endpoint 로 복구. 운영에선 cat > 로 같은 inode 에 써야 함
- 30MB 차트(big30-0.1.0.tgz, 31,467,160 B, sha 97f6064bf73ee328) 를 Nexus 식 `curl -u ci-helm -T …/repository/helm-hosted/big30-0.1.0.tgz` → **201, 4.95s** (6절 이전엔 413). index.yaml 반영, 엔드포인트 재다운로드 sha256 일치, helm pull 결과는 아래
- 한계: helm upgrade 를 다시 돌리면 ConfigMap 이 chart 템플릿의 20971520 으로 되돌아간다 → 템플릿 한 줄 수정본을 쓰거나 upgrade 뒤 patch 재적용 필요. 시험 차트 big30 은 Harbor 2.7 에 남아 있음(시험 데이터)
