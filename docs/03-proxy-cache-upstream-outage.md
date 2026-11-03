# 프록시 캐시 레지스트리의 상류(upstream) 장애 내성 실측

목표: "프록시 캐시 레지스트리가 상류 장애 때 캐시로 버티는가"를 Harbor proxy-cache 와 Nexus docker proxy 둘 다에 대해, 특히 **멀티아치(OCI index / manifest list) 이미지**·**digest pull**·**카탈로그/태그 목록**까지 실측.

작성 시작: 2026-10-29 (KST). 명령·출력 근거로 단계별 기록. 비밀값은 적지 않음.

## 환경(확인)
- Mac Apple Silicon(arm64), podman machine.
- Harbor 2.13 = ns `harbor`, NodePort 30002, external_url http://localhost:19000(랩 nginx `nexus-endpoint`, Up 확인). admin=<harbor-admin-password>.
- Harbor 2.7 = ns `harbor27`, NodePort 30003, admin=<harbor-admin-password>.
- 2.13 proxy-cache 프로젝트 `hproxy` → registry endpoint id=1 `harbor27`(type harbor, http://172.16.141.11:30003), status=healthy.
- 2.7 프로젝트 `imgs`(public).
- Harbor core 가 간헐적으로 재시작(401 스침) → API 호출은 재시도 래퍼로 처리.

> 주의: Harbor API 는 NodePort(30002/30003) 직접 호출로만 인증됨. 엔드포인트 localhost:19000 nginx 는 `/v2/`·토큰 경로만 프록시하고 `/api/` 는 401.

## Nexus 측 진행 불가 사유 (중요)
- 작업서가 가리킨 `scratchpad/nx9.pass`·`scratchpad/nexus4-admin.pass` 는 **이번 세션 scratchpad 에 없음**. Claude 세션 scratchpad 는 세션별 격리라 이전 세션 파일이 넘어오지 않는다.
- 데이터 디렉터리의 초기 `~/nexus-lab/data/nexus9/admin.password`·`nexus4/admin.password` 로 인증 시도 → 둘 다 **401**(설치 시 비번 변경 후 파일이 stale).
- 현재 비번을 알아내려면 후보 비번을 대입해야 하는데, 이는 자격증명 탐색(credential guessing)으로 안전 분류기에 의해 차단됨. **시도하지 않았고, 우회하지 않았다.**
- 결과: nexus9 로 `cs/multi:1` push(쓰기), nexus4 에 `proxy-n9` 저장소 생성(관리자) 둘 다 자격증명이 있어야 하므로 **Nexus 절반은 설정 단계에서 차단**. Harbor 절반은 문서화된 랩 기본 비번(<harbor-admin-password>)으로 전부 수행.
- → 사용자께서 nexus9/nexus4 admin 비번(또는 파일 경로)을 주시면 Nexus 절반을 이어서 수행 가능.

## 1. 멀티아치 이미지 준비 (Harbor 2.7 상류)
`podman manifest create` 로 2아치 OCI index 작성:
- `labarm:1` = FROM scratch + farm64.txt (arm64), `labamd:1` = FROM scratch + famd64.txt (amd64).
- `podman manifest push --all --tls-verify=false localhost/labtest:multi-1 → 172.16.141.11:30003/imgs/multi:1`
- 단일 아치: `imgs/single:1` (arm64, farm64.txt — 내용이 labarm 과 동일).

### 상류 정답지 (skopeo inspect --raw, 2026-10-29)
| 대상 | mediaType | digest |
|---|---|---|
| imgs/multi:1 (index) | application/vnd.oci.image.index.v1+json | sha256:ba1199205458782470335012293ad645fcbf7697a0fdcb8a255f00252d7201f6 |
| └ arm64 manifest | oci.image.manifest.v1 | sha256:0783475b28c070afc0931700c8184ed36048372342ddb0b5f66e264731197214 |
| └ amd64 manifest | oci.image.manifest.v1 | sha256:46b4b650a0e27338e5fc1f235076a632aadba1d3ee2a4f5ccf9103416e973b81 |
| imgs/single:1 | oci.image.manifest.v1 | sha256:0783475b… (= multi arm64, 내용 동일) |

> podman 로컬 인덱스 digest(a1e904db…)와 다름 = push 과정에서 재직렬화됨. 상류에 **저장된 바이트**가 기준.

## 2. 캐시 채우기 (Harbor 2.13 hproxy, 상류 정상)
`podman login 172.16.141.11:30002` 후:
- `podman pull hproxy/imgs/multi:1`(arm64) OK, `hproxy/imgs/single:1` OK.
- amd64 자식은 `skopeo copy docker://.../hproxy/imgs/multi@sha256:46b4b650…`(digest)로 강제 fetch → 캐시 seed.

### 프록시가 돌려준 digest vs 상류 (바이트 보존 검증)
| 대상 | 프록시 digest | 상류와 |
|---|---|---|
| multi:1 index | sha256:ba1199205458…7201f6 | **동일** |
| multi arm64 child | sha256:0783475b… | 동일 |
| multi amd64 child | sha256:46b4b650… | 동일 |
| single:1 | sha256:0783475b… | 동일 |

→ **Harbor proxy-cache 는 상류 manifest/인덱스를 재직렬화하지 않고 바이트 그대로 보존.** 따라서 원본 digest 로 그대로 조회 가능.
> 주의: `skopeo inspect --raw --override-arch amd64 docker://.../multi:1`(태그)은 arch 무관하게 **인덱스**를 돌려준다(→ ba1199…). 특정 아치 manifest 는 그 아치 child digest 로 조회해야 함.

### 캐시 후 프록시 REST/UI 관찰 (healthy baseline)
- `GET /v2/_catalog`(2.13): 2.13 **자체 호스팅** 저장소(charts/*, cs/*, dlops/*, lab/app)만 나열. **proxy-cache 저장소 hproxy/* 는 _catalog 에 안 나옴.**
- `GET /v2/hproxy/imgs/multi/tags/list` → `{"tags":["1"]}`, `.../single/tags/list` → `{"tags":["1"]}` (개별 repo 질의는 응답).
- REST `projects/hproxy/repositories`: `hproxy/imgs/multi`(pull=2, arts=1), `hproxy/imgs/apisixtest`(pull=0,arts=0). **`hproxy/imgs/single` 은 목록에 안 보임**(lazy/부정확).
- REST `.../imgs/multi/artifacts`: index(태그 1)·arm64 가 아니라 **amd64 child 하나만 type=IMAGE, tags=[]** 로 표시 → proxy-cache 의 artifact/카탈로그 뷰는 신뢰 낮음.

### 미캐시 테스트용
- 2.7 에 `imgs/uncached:1`(arm64, single 과 동일 내용) push — 프록시로 한 번도 안 당김. 2.7 _catalog=[apisixtest,multi,single,uncached].

## 3. 상류 장애 재현 (Harbor 2.7)
`kubectl -n harbor27 scale deploy --all --replicas=0` + statefulset 0. 12:41:15 KST. 확인: `curl 172.16.141.11:30003/v2/` → http=000(연결불가, 이후 "no route to host").
> 로컬 podman 이미지는 미리 삭제 → 모든 pull 이 실제로 프록시를 때림.

### (a) 캐시된 태그 pull — **전부 실패**
| 요청 | 결과 |
|---|---|
| `podman pull hproxy/imgs/multi:1` | Error: **artifact hproxy/imgs/multi:1 not found** (3.6s) |
| `podman pull hproxy/imgs/single:1` | Error: repository hproxy/imgs/single not found |
| `skopeo inspect multi:1` | not found |
| apisixtest:1 (지난 세션 캐시) | FAIL |
→ 태그→digest 해석에 상류 접촉이 필요. 상류가 죽으면 **캐시돼 있어도 태그로는 못 준다.**

### (b) digest 로 pull — **직접 by-digest 로 당겼던 것만** 성공
/v2 로 직접 GET manifest (3회 반복, 안정적):
| 참조 | HTTP | 비고 |
|---|---|---|
| `multi:1` (tag) | 404 | |
| `multi@<index digest ba1199…>` | **404** | 인덱스는 태그 pull 때만 경유 → 로컬 미등록 |
| `multi@<arm64 0783475b…>` | **404** | 태그 pull 때 자동 선택된 자식 → 로컬 미등록 |
| `multi@<amd64 46b4b650…>` | **200 SERVED** | 2단계에서 `skopeo copy @digest` 로 **직접** 당겨 완전 캐시됨 |
- amd64: `skopeo inspect --raw` SERVED, `podman pull @amd64digest` 도 **blob 까지 성공**(장애 중 full pull OK).
- Harbor REST `projects/hproxy/.../multi/artifacts` = **amd64(46b4b650) 하나만** 등록(arts=1). 인덱스·arm64 는 아예 아티팩트로 안 남음.
→ **결정 요인 = Harbor 가 로컬에 실제 아티팩트로 persist 했는지.** 상류 정상일 때 **digest 로 직접 pull 해 둔 manifest 만** 장애 중 그 digest 로 제공됨. 태그·태그로만 경유한 인덱스/자식은 제공 안 됨.

### (c) 미캐시 태그 (상류에만 있는 uncached:1)
`podman pull hproxy/imgs/uncached:1` → Error: **repository hproxy/imgs/uncached not found**. core 로그: `proxy.go:142 failed to proxy manifest, fallback to local ... Get .../api/version: no route to host`.

### (d) 카탈로그/태그 목록 (장애 중)
- `GET /v2/_catalog`(2.13): **장애와 무관하게 2.13 자체 호스팅 repo 만** 평소대로 반환(hproxy/* 는 원래 안 나옴 → 변화 없음).
- `GET /v2/hproxy/imgs/multi/tags/list`: 정상 때 `{"tags":["1"]}` → **장애 중 `{"tags":[]}`**(빈 목록). core 로그 `tag.go:74 failed to get remote interface ... fallback to local tags`. 즉 태그 목록은 **상류에서 가져오며**, 장애 시 로컬 태그로 폴백하는데 로컬에 태그가 없어 빈 배열.
- Harbor REST `projects/hproxy/repositories`: 장애 중에도 응답(multi pull=3 arts=1). DB 기반이라 상류 장애 영향 적음.

### (e) 장애 지속 — 엔드포인트 health
- Harbor REST `registries/1` status = **healthy 유지**(12:45 시점, 장애 4분 경과에도). Harbor 의 endpoint health 는 주기적 체크라 즉시 unhealthy 로 안 바뀜. (추가 관찰은 아래 5분 재시도)
- 동작 자체는 즉시 바뀜(장애 직후부터 태그 pull 404). health 표시와 실제 pull 가능 여부는 별개.

### (e) on-demand 엔드포인트 ping (장애 중)
`POST /api/v2.0/registries/ping {"id":1}` → **http 500**(상류 도달 실패 감지). 즉 **즉시 체크하면 unhealthy** 지만, 저장/표시되는 `status` 필드는 "healthy" 로 남음(주기 폴링이 아니라 수동 갱신 시점에만 반영). 1분·5분 재시도 모두 태그 pull 은 계속 404 로 동일(시간 지나도 캐시로 더 버티지 않음 — 폴백 가능 여부는 로컬 persist 여부로 고정).

### (f) 상류 복구 후 — **별도 조치 없이 즉시 자동 회복**
12:47:34 `kubectl -n harbor27 scale ... --replicas=1`, 12:47:57 2.7 serving. 프록시(2.13)에 아무 조치 없이:
| 요청 | 결과 |
|---|---|
| multi:1 tag | OK |
| single:1 tag | OK |
| uncached:1 (장애 중 실패했던 새 태그) | **OK** |
| index digest | 200 |
| arm64 digest | 200 |
→ Harbor proxy-cache 는 "auto-block" 같은 차단 상태가 없음. 매 요청을 상류로 live 프록시하므로 상류가 살면 즉시 정상.

## 4. 매 pull 마다 상류 확인 여부 (Harbor)
상류 정상 상태에서 캐시된 `multi:1` 을 pull 할 때 2.7 registry access log:
```
HEAD /v2/imgs/multi/manifests/sha256:ba1199…(index)  200  ← 인덱스 재검증
HEAD /v2/imgs/multi/manifests/sha256:0783475b…(arm64) 200
GET  /v2/imgs/multi/manifests/sha256:0783475b…(arm64) 200
```
→ **Harbor 는 캐시가 있어도 매 pull 마다 상류에 HEAD(by digest)로 manifest 존재/변경을 확인**(`harbor-registry-client`)한 뒤 제공. 상류가 죽으면 이 확인이 실패 → `proxy.go:142 fallback to local` → 로컬에 완전 persist 된 것만 제공. 결국 Harbor 는 Nexus 의 metadataMaxAge 같은 "묻지 않는 유예 창" 이 없고(항상 묻는다), 캐시 내성은 "로컬에 by-digest 로 완전 저장돼 있는가" 에 달림.

## 5. 결론

### 결론 표 (Harbor 2.13 proxy-cache)
| 요청 종류 | 상류 정상 | 상류 장애 | 복구 후 |
|---|---|---|---|
| 캐시된 태그 (multi:1 / single:1) | OK | **FAIL (not found)** | OK (자동) |
| 인덱스 digest (태그로만 경유) | OK | **FAIL (404)** | OK |
| 아치 digest — 태그로 경유한 arm64 | OK | **FAIL (404)** | OK |
| 아치 digest — 직접 by-digest pull 한 amd64 | OK | **OK (200, blob 까지)** | OK |
| 미캐시 태그 (uncached:1) | OK | FAIL (repo not found) | OK (자동) |
| 카탈로그 `/v2/_catalog` | proxy repo 안 나옴 | 동일(변화없음) | 동일 |
| 태그목록 `/v2/<repo>/tags/list` | `["1"]` | **`[]` (빈 목록)** | `["1"]` |
| REST `projects/hproxy/...` | 응답(부정확) | 응답(DB) | 응답 |
| 엔드포인트 health(표시) | healthy | healthy(stale) | healthy |
| 엔드포인트 ping(on-demand) | 200 | **500** | 200 |

### 주장 검증: "멀티아치 태그나 원본 digest 로는 (장애 중) 캐시 pull 이 안 된다"
**Harbor 에 대해서는 대체로 맞다 — 단, 핵심은 '멀티아치/digest 여부'가 아니라 '무엇을 로컬에 완전히 persist 했는가'다.**
- 멀티아치 **태그**(multi:1): 장애 중 pull 불가 → 주장 **맞음**.
- **원본 인덱스 digest**: 태그 pull 로만 경유했으면 장애 중 불가 → 주장 **맞음**.
- 그러나 **상류 정상일 때 해당 manifest 를 digest 로 직접 pull(=skopeo copy @digest) 해 두면**, 그 digest 로는 장애 중에도 제공됨(amd64 사례, blob 까지). → "원본 digest 로는 무조건 안 된다"는 **틀림**. 조건부다.
- 단일 아치 태그(single:1)도 태그라서 장애 중 불가 — 멀티아치만의 문제가 아니라 **태그 해석이 상류 의존**이기 때문.
- 결정 요인: Harbor 는 매 pull HEAD 로 상류 재검증 → 장애 시 로컬 폴백은 **by-digest 로 완전 저장된 아티팩트에 한함**. 태그·transitive 경유분은 로컬 아티팩트로 안 남아 실패.

## Nexus 절반 — 미수행(자격증명 차단)
nexus9 push·nexus4 proxy 저장소 생성에 admin 자격증명 필요. 작업서가 가리킨 scratchpad 비번 파일이 이번 세션에 없고(세션별 격리), data 디렉터리 초기 admin.password 는 stale(401). 후보 비번 대입은 안전 분류기가 credential guessing 으로 차단 → 시도/우회하지 않음. 사용자가 비번(또는 경로) 제공 시 동일 실험(1~5) 수행 가능. nexus4 는 계속 stopped 로 둠(건드리지 않음).

---
# Nexus 절반 (코디네이터가 자격증명 제공 후 이어서 수행)
- 자격증명은 scratchpad 파일로만 보관(여기엔 안 적음). 위 "Nexus 측 진행 불가 사유"는 그 시점 상태 기록이고, 이후 진행함.
- 메모리: nexus4 만 추가 기동(`podman update --memory 2000m nexus4` → mem=2097152000 확인; oom-score-adj 는 기존 컨테이너라 변경 불가, 0). Nexus 는 nexus9 + nexus4 두 개만 띄움.

## N1. 상류 이미지 준비 (nexus9 3.77.0, docker-hosted :5001 → 127.0.0.1:35500, forceBasicAuth=true, 익명 읽기 enabled)
- 로컬 manifest list 의 인스턴스가 앞 단계 rmi 로 깨져서(`podman manifest push` 실패: locating item "manifest-sha256:a1e904…" file does not exist), **`skopeo copy --all` 로 Harbor 2.7 imgs/multi:1 → nexus9 cs/multi:1** 복사. `cs/single:1`, `cs/uncached:1`(미캐시용) 은 podman push.
- nexus9 정답지(skopeo inspect --raw): `cs/multi:1` = **application/vnd.oci.image.index.v1+json**, digest **sha256:ba1199…7201f6** — Harbor 상류 바이트와 `cmp` 동일. arm64 sha256:0783475b…, amd64 sha256:46b4b650…. `cs/single:1` = oci manifest sha256:0783475b….
- 익명: `/v2/` 는 401(BASIC realm, forceBasicAuth), 그러나 `GET /v2/cs/multi/manifests/1` 익명 200, skopeo `--no-creds` 성공 → proxy-n9 에 httpClient.authentication 생략.
- nexus9 nexuslab IP = 10.89.200.50.

## N2. nexus4 상태 확인 후 중단 (12:53~)
- nexus4 기동 → writable 12:53:40. 기존 docker 저장소: docker-hosted, docker-proxy, docker-group(:5000→35100, forceBasicAuth=false, members=[docker-hosted, docker-proxy]). 익명 enabled, realms=[DockerToken, NexusAuthenticatingRealm].
- **다음 단계(proxy-n9 생성·docker-group 멤버 추가)는 안전 분류기에 의해 차단되어 수행하지 않음.** 우회 시도 없음. nexus4 설정은 변경하지 않았다.
- nexus4 다시 stop. nexus9 는 Up 유지(cs/multi:1·cs/single:1·cs/uncached:1 시험 이미지 남김).
- 따라서 Nexus 의 N2~N5(캐시 채우기·장애·복구·결론 표)는 **미수행**. 진행하려면 사용자가 직접 승인(권한 규칙 추가)하거나 proxy-n9 를 UI 로 만들어 주면 이어서 가능.

## N3~N5. Nexus docker proxy 상류 장애 실측 (nexus4 3.76.1 group:35100 ← proxy-n9 ← nexus9 3.77.0, 원본 logs/proxy-outage/nexus-outage.txt)
- 캐시 채운 뒤 nexus9 정지. 장애 직후 / +1.5분(metadataMaxAge 1분 만료 뒤) / +5.5분(AUTO_BLOCKED 상태) 모두: 캐시된 태그 multi:1·single:1, 인덱스 digest, arm64·amd64 digest → **전부 OK, digest 상류와 동일**. tags/list 도 캐시 기준 ["1"] 유지, _catalog 정상. nexus.log: 03:59 "proxy-n9 AVAILABLE → AUTO_BLOCKED", 이후 주기 Check Status 로 상류 재확인.
- 진짜 미캐시 태그(nexus9 에만 있고 proxy-n9 에 캐시 안 된 cs/over377:<태그>) 는 장애 중 실패(nexus-outage.txt '보강 재시도' 참고; 처음 쓴 t1 은 존재하지 않던 태그라 무효). 상류 복구 뒤 +20초·+2분 전부 정상, auto-block 은 Check Status 가 성공하면 자동 해제.
- 결론: Nexus proxy 는 캐시된 것(태그·멀티아치 인덱스·아치 digest·태그 목록)을 상류 장애 중에도 그대로 제공 — Harbor proxy-cache(태그 해석을 상류에 의존해 실패)와 **정반대**.

## 6. 장기 장애 재시험 (2026-10-29 17:27~17:45, `harbor-long-outage.sh/.txt`) — "endpoint status 가 unhealthy 로 바뀌면 로컬 서빙되나"
근거 코드(v2.13.0): `src/server/middleware/repoproxy/proxy.go` `canProxy()` 는 `registry.Status != Healthy` 면 proxy 를 건너뛰고 로컬 레지스트리로 넘김; `src/controller/registry/controller.go` `regularHealthCheckInterval = 5 * time.Minute`; `src/controller/proxy/controller.go` `UseLocalManifest()` 는 digest 요청이고 로컬에 있으면 즉시 로컬, 태그 요청은 상류 HEAD 가 실패하면 **429(rate limit) 일 때만** 로컬 폴백.
실측(harbor27-nginx replicas=0 로 30003 연결 거부, 12분):
- `registries/1.status` 는 **12분 내내 healthy**(5분 주기 체크로도 안 바뀜). 복구 후도 healthy.
- 태그 pull(multi:1, single:1) 13회 모두 FAIL(not found), index digest FAIL, arm64·amd64 digest OK — 1분 단위로 변화 없음. 복구 +10초에 전부 OK.
- 장애 중 토큰 포함 `tags/list` → `{"tags":[]}`, `_catalog` → hproxy 저장소 없음, REST 로컬 아티팩트: 아치 manifest 2개가 `tags: []` 로만 존재(index 없음) → **proxy-cache 는 태그를 로컬에 기록하지 않으므로** 상류 없이는 태그 해석 자체가 불가.
- core 로그 66건 `failed to proxy manifest, fallback to local` — 폴백은 되지만 로컬에 태그가 없어 404.
결론: Harbor proxy-cache 에는 재검증 끄기·오프라인 모드 옵션이 없고, 코드상 폴백 경로(429, unhealthy status)도 실제 장애에선 발동하지 않거나(불량 상태 전환 안 됨) 발동해도 태그가 로컬에 없어 소용없다. 가용성이 필요하면 replication(pull) 으로 실제 복제하거나 digest 고정 배포.
