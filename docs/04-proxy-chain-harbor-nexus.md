# 프록시 체인 실측 (2026-10-26)
## Harbor → Harbor (proxy cache 프로젝트)
- 2.13(ns harbor, 30002) 에 registry endpoint type=harbor url=http://172.16.141.11:30003(2.7) → status healthy → 프로젝트 hproxy(registry_id) 생성.
- 2.7 imgs/apisixtest:1 을 2.13 `hproxy/imgs/apisixtest:1` 로 pull: digest 동일(sha256:5deb82a2…), podman pull 3회 OK. 원본 2.7 pull_count 1 → 1 → 1 (2회째부터 캐시 히트). 2.7 registry 로그 blob GET 4건(1벌).
- 반대 방향(2.7 → 2.13)은 실패: 2.13 의 external_url 이 랩 엔드포인트(localhost:19000)라 2.7 core 가 토큰 realm 에 못 닿음("failed to ping registry … localhost:19000/service/token"). → **프록시하는 Harbor 가 원본 Harbor 의 external_url(토큰 realm)에 닿아야 함.** 운영은 엔드포인트 도메인이라 해당 없음.
- 경로: 클라이언트는 `<프록시Harbor>/<proxy프로젝트>/<원본프로젝트>/<repo>` 로 받음(접두사 추가). ChartMuseum(2.7) 차트는 OCI 가 아니라 proxy 대상 아님(복제도 OCI 만).
## Nexus → Nexus
- 기존 실측: nexus2 docker-proxy remote=nexus1 docker-group(S2 배치 12 PASS), nexus2 <fmt>-from-n1 proxy(maven/npm/pypi/raw/rubygems/nuget/helm, 110케이스), nexus4(3.76.1) docker-proxy → nexus1 원격 fetch OK. 원본 Nexus 에는 miss 마다 /repository/ 요청이 찍혀 한도에 셈.
