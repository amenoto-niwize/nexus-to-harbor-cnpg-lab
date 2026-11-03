# Nexus → Harbor + CloudNativePG 이관 실측 랩

폐쇄망에서 운영 중인 Nexus Repository(3.82 CE)의 **커스텀 docker 이미지·helm 차트만** Harbor 로 옮기고, Harbor 의 DB 를 CloudNativePG(CNPG) 로 두는 구성을 랩 클러스터에서 **처음부터 끝까지 실제로 구축·이관·검증**한 기록입니다. Nexus 는 그대로 유지합니다.

모든 수치는 실측값이고, 겪은 이슈와 주의점을 해당 단계에 함께 적었습니다.

## 구성

| 항목 | 랩(검증) | 운영 권장 |
|---|---|---|
| Harbor | 2.14.0 (chart 1.18.0, arm64 빌드 `ghcr.io/octohelm/harbor/*`) | **2.15.4 (chart 1.19.4, 공식 `goharbor/*`)** — 공식 이미지는 amd64 전용 |
| CNPG operator | 1.30.1 (chart cloudnative-pg 0.29.1) | 동일 |
| PostgreSQL | 16.15 (`ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm`) | 동일, instances 3 |
| helm 차트 저장 | OCI 아티팩트 (`helm push/pull oci://`) | 동일 — ChartMuseum 없음 |
| 1차 비교 대상 | Harbor 2.7.0 (chart 1.11.0, ChartMuseum 있음) | 참고용 |

## 문서

| 파일 | 내용 |
|---|---|
| [docs/01-harbor-cnpg-migration-lab.md](docs/01-harbor-cnpg-migration-lab.md) | **본 문서.** 반입 → CNPG → Harbor(2.7 → 2.14) → 프로젝트/로봇 → 이관 → 검증 → DB 재시작/백업 실측 |
| [docs/02-harbor27-chartmuseum-helm-path.md](docs/02-harbor27-chartmuseum-helm-path.md) | Harbor 2.7 ChartMuseum 경로 유지 시험(업로드 한도, 덮어쓰기, 부하) |
| [docs/03-proxy-cache-upstream-outage.md](docs/03-proxy-cache-upstream-outage.md) | Harbor proxy-cache vs Nexus proxy — 상류 장애 때 캐시로 버티는가(멀티아치·digest·태그목록) |
| [docs/04-proxy-chain-harbor-nexus.md](docs/04-proxy-chain-harbor-nexus.md) | Harbor→Harbor, Nexus→Nexus 프록시 체인 |

## 코드

| 파일 | 용도 |
|---|---|
| `harbor-cnpg/harbor-pg.yaml` | Harbor 전용 CNPG Cluster (initdb registry/harbor, smartShutdownTimeout 15) |
| `harbor-cnpg/values-harbor214-cnpg.yaml` | Harbor 2.14/2.15 values — 외부 DB(existingSecret, sslmode require, maxOpenConns 50), 관리자 Secret |
| `harbor-cnpg/values-harbor-cnpg.yaml` | (1차) Harbor 2.7 + ChartMuseum values |
| `harbor-cnpg/harbor214-setup.sh` | 프로젝트 2개 + 시스템 로봇 생성 |
| `harbor-cnpg/migrate-nexus-to-harbor-oci.sh` | **이관 스크립트** (셸: curl·python3·skopeo·helm). docker = skopeo copy + digest 대조, helm = OCI push. 재실행 안전 |
| `harbor-cnpg/migrate-nexus-to-harbor.sh` | (1차) 2.7 ChartMuseum 용 |
| `harbor-cnpg/pg-restart-test.sh` | CNPG 파드 재시작 중 pull/API/push 가용성 측정 |
| `harbor-cnpg/seed-source.sh` | 원본 Nexus 에 시험 데이터 심기 |
| `logs/` | 각 실행의 원본 출력 |

스크립트의 주소·포트·경로는 랩 값입니다(172.16.141.x, NodePort 30004, scratchpad 경로). 비밀값은 저장소에 없고 별도 파일에서 읽습니다.

## 핵심 실측 결과

- **이관**: 이미지 7개(단일아치·OCI·멀티아치 index·동일 digest 태그 3개·60MB) 복사 후 **digest 전부 원본과 동일**, 차트 6개 OCI push 후 `helm pull oci://` 로 받은 tgz **원본과 바이트 동일**. 재실행 시 전부 건너뜀, 원본에 추가분이 있으면 그것만 복사(델타 동기화).
- **클러스터 배포**: Harbor 의 OCI 차트 + Harbor 의 이미지로 `helm install` → Running, 서비스 200, 파드 imageID = 이관 digest. 멀티아치 태그는 노드가 자기 아키텍처 선택.
- **CNPG 파드 재시작**: 기본 `smartShutdownTimeout`(180s)이면 193초(Harbor 커넥션 풀이 안 끊겨 대기), 15초로 두면 28초. 실제 서비스 끊김은 둘 다 ~11초. **DB 가 없는 동안 pull 도 401** — DB 장애 = 레지스트리 장애.
- **백업**: `pg_dump -Fc` 무중단 → 새 CNPG 클러스터에 복구, 행 수 일치. 백업 대상은 **DB + registry 저장소** 두 곳.

## 겪은 이슈 (전부 해결)

| 이슈 | 원인 | 해결 |
|---|---|---|
| 1차 이관 docker 전부 `trying to reuse blob`, 차트 401 | 로봇 이름 `robot$migrator` 의 `$` 가 셸 변수로 풀려 사용자명이 `robot` | 비밀값 파일을 작은따옴표로 저장 |
| `kubectl apply` CNPG 매니페스트 실패 `annotations: Too long` | CRD 크기 | `kubectl apply --server-side` |
| Harbor 차트 `maxOpenConns` 기본 900 | PG `max_connections` 200 초과 | 50 으로 조정 |
| jobservice 초기 2회 재시작 | redis 준비 전 기동 | 정상, 조치 불필요 |
| 로봇으로 프로젝트 저장소 목록 API 403 | 로봇 권한 범위 | 개별 아티팩트 목록은 200; 전체 목록은 admin 으로 |
| 공식 goharbor 2.15 이미지 arm64 없음 | amd64 단일 아키 | arm64 랩은 2.14.0(octohelm) |

## 사용자 체감 변경 (ChartMuseum → OCI)

`helm repo add` / `helm search repo` 는 없어집니다. `helm registry login <harbor>` 후 `helm pull oci://<harbor>/charts/<이름> --version <버전>`, 배포는 `helm install <릴리스> oci://<harbor>/charts/<이름> --version <버전>`. 버전 검색은 Harbor UI 또는 API. helm 3.8 이상 필요.

## 컷오버 순서

1. (무영향) Harbor·CNPG 구축, 초기 동기화, 검증
2. Nexus 의 docker-hosted·helm-hosted 를 Read-only 로 전환
3. 델타 동기화 → 검증
4. CI push 대상, 배포 매니페스트의 이미지 호스트·차트 참조(`oci://`)를 Harbor 로 변경 (이미지 경로는 유지)
5. Nexus 의 두 저장소는 읽기 전용으로 남겨 롤백 경로로, 안정 후 삭제. 다른 저장소는 손대지 않음
