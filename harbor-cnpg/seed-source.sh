#!/bin/bash
# 이관 원본(nexus6, 3.82) 에 커스텀 docker 이미지·helm 차트를 심는다 (운영 형태 흉내)
set -uo pipefail
cd ~/nexus-lab
B=http://127.0.0.1:8096; A="admin:$(cat data/nexus6/admin.password)"; D=127.0.0.1:35600
OUT=logs/harbor-cnpg/seed.txt; : > $OUT
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
cp_img(){ # cp_img <src> <dst> [extra skopeo args]
  local src=$1 dst=$2; shift 2
  if skopeo copy -q --src-tls-verify=false --dest-tls-verify=false --dest-creds "$A" "$@" "$src" "docker://$D/$dst" 2>/tmp/seed.err; then log "  docker: $dst ← $src"; else log "  실패 $dst: $(tail -1 /tmp/seed.err | cut -c1-150)"; fi; }

log "== docker 이미지"
cp_img dir:scratch/zalp dlops/app1:1.0 --format v2s2
cp_img dir:scratch/zalp dlops/app1:1.1 --format v2s2
cp_img dir:scratch/zalp dlops/app1:latest --format v2s2          # 1.1 과 같은 digest 를 공유하는 태그
cp_img dir:scratch/zalp dlops/app2:2.0 --format oci
cp_img docker://localhost:35500/cs/multi:1 dlops/multi:1 --all --preserve-digests   # OCI index(arm64+amd64)
cp_img docker://docker.io/library/python:3.12-alpine dlops/pybase:3.12 --override-arch arm64   # 실사용 크기(≈60MB)

log "== helm 차트 (3종 × 2버전)"
T=$(mktemp -d)
for c in h27a h27b h27c; do
  for v in 0.1.0 0.2.0; do
    rm -rf $T/$c && cp -r logs/harbor27/charts/$c $T/$c
    sed -i '' -E "s/^version:.*/version: $v/" $T/$c/Chart.yaml
    helm package $T/$c -d $T >/dev/null
    f=$T/$c-$v.tgz
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$A" --upload-file $f "$B/repository/helm-hosted/$c-$v.tgz")
    log "  helm: $c-$v.tgz ($(stat -f %z $f) B, sha256 $(shasum -a 256 $f | cut -c1-12)) → $code"
  done
done
rm -rf $T

log "== 원본 목록(정답지)"
python3 - "$A" "$B" <<'EOF' | tee -a ~/nexus-lab/logs/harbor-cnpg/seed.txt
import sys,json,urllib.request,base64
a,b=sys.argv[1],sys.argv[2]
h={'Authorization':'Basic '+base64.b64encode(a.encode()).decode()}
def get(u):
    return json.load(urllib.request.urlopen(urllib.request.Request(u,headers=h)))
for repo in ('docker-hosted','helm-hosted'):
    items=[];tok=None
    while True:
        d=get(f"{b}/service/rest/v1/components?repository={repo}"+(f"&continuationToken={tok}" if tok else ""))
        items+=d['items'];tok=d.get('continuationToken')
        if not tok: break
    print(f"  {repo}: {len(items)} 컴포넌트 → {sorted((c['name'],c['version']) for c in items)}")
EOF
