#!/bin/bash
# Nexus(docker-hosted, helm-hosted) → Harbor 2.8+ (ChartMuseum 없음: 차트는 OCI 아티팩트)
# 필요 도구: curl, python3, skopeo, helm ≥3.8 (OCI). 재실행 안전(이미 있으면 건너뜀).
set -uo pipefail
NX=${NX:-http://127.0.0.1:8096}; NX_DOCKER=${NX_DOCKER:-127.0.0.1:35600}
NX_DOCKER_REPO=${NX_DOCKER_REPO:-docker-hosted}; NX_HELM_REPO=${NX_HELM_REPO:-helm-hosted}
NXA=${NXA:?Nexus user:pass}
HB=${HB:-http://172.16.141.11:30004}; HB_REG=${HB_REG:-172.16.141.11:30004}
HB_CHART_PROJECT=${HB_CHART_PROJECT:-charts}; DEFAULT_PROJECT=${DEFAULT_PROJECT:-dlops}
HBA=${HBA:?Harbor user:pass (로봇)}
TLS=${TLS:---src-tls-verify=false --dest-tls-verify=false}; HELM_HTTP=${HELM_HTTP:---plain-http}   # 운영(https) 은 둘 다 빈 값
WORK=${WORK:-/tmp/nx2hb}; mkdir -p $WORK/charts; OUT=${OUT:-$WORK/migrate.log}; : > $OUT
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
map_repo(){ case "$1" in */*) echo "$1";; *) echo "$DEFAULT_PROJECT/$1";; esac; }
nx_components(){ python3 - "$NX" "$NXA" "$1" <<'EOF'
import sys,json,urllib.request,base64
b,a,repo=sys.argv[1:4]; h={'Authorization':'Basic '+base64.b64encode(a.encode()).decode()}; tok=None
while True:
    u=f"{b}/service/rest/v1/components?repository={repo}"+(f"&continuationToken={tok}" if tok else "")
    d=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=h)))
    for c in d['items']:
        asset=next((x for x in c['assets'] if x['path'].endswith('.tgz')), c['assets'][0] if c['assets'] else {})
        print("\t".join([c['name'],c['version'],asset.get('checksum',{}).get('sha256',''),asset.get('downloadUrl','')]))
    tok=d.get('continuationToken')
    if not tok: break
EOF
}
digest_of(){ skopeo inspect --raw $1 "$2" 2>/dev/null | shasum -a 256 | cut -c1-64; }
HB_USER=${HBA%%:*}; HB_PASS=${HBA#*:}

log "===== 1. docker: $NX_DOCKER_REPO → $HB_REG"
nx_components $NX_DOCKER_REPO > $WORK/docker.lst; log "원본 이미지 태그 수: $(wc -l < $WORK/docker.lst | tr -d ' ')"
ok=0; skip=0; fail=0; : > $WORK/docker-result.tsv
while IFS=$'\t' read -r name ver _ _; do
  src="docker://$NX_DOCKER/$name:$ver"; dst="docker://$HB_REG/$(map_repo $name):$ver"
  sd=$(digest_of "--tls-verify=false --creds $NXA" "$src"); td=$(digest_of "--tls-verify=false --creds $HBA" "$dst")
  if [ -n "$td" ] && [ "$sd" = "$td" ]; then skip=$((skip+1)); printf '%s:%s\tSKIP\t%s\n' "$name" "$ver" "${sd:0:12}" >> $WORK/docker-result.tsv; continue; fi
  if skopeo copy -q --all --preserve-digests $TLS --src-creds "$NXA" --dest-creds "$HBA" "$src" "$dst" 2>$WORK/err; then
    td=$(digest_of "--tls-verify=false --creds $HBA" "$dst"); if [ "$sd" = "$td" ]; then ok=$((ok+1)); r=OK; else fail=$((fail+1)); r=DIGEST_MISMATCH; fi
  else fail=$((fail+1)); r="FAIL $(tail -1 $WORK/err | cut -c1-100)"; fi
  printf '%s:%s\t%s\t%s→%s\n' "$name" "$ver" "$r" "${sd:0:12}" "${td:0:12}" >> $WORK/docker-result.tsv
done < $WORK/docker.lst
log "docker 결과: 복사 $ok / 건너뜀 $skip / 실패 $fail"; sed 's/^/  /' $WORK/docker-result.tsv | tee -a $OUT

log "===== 2. helm(OCI): $NX_HELM_REPO → oci://$HB_REG/$HB_CHART_PROJECT"
nx_components $NX_HELM_REPO > $WORK/helm.lst; log "원본 차트 버전 수: $(wc -l < $WORK/helm.lst | tr -d ' ')"
helm registry login $HB_REG $HELM_HTTP --username "$HB_USER" --password "$HB_PASS" >/dev/null 2>&1 && log "helm registry login OK" || log "helm registry login 실패"
ok=0; skip=0; fail=0; : > $WORK/helm-result.tsv
while IFS=$'\t' read -r name ver sha url; do
  # 존재 확인: Harbor API (프로젝트 charts 의 저장소 <name>, 태그 <ver>)
  have=$(curl -s -o /dev/null -w '%{http_code}' -u "$HBA" "$HB/api/v2.0/projects/$HB_CHART_PROJECT/repositories/$name/artifacts/$ver")
  if [ "$have" = 200 ]; then skip=$((skip+1)); printf '%s-%s\tSKIP\n' "$name" "$ver" >> $WORK/helm-result.tsv; continue; fi
  f=$WORK/charts/$name-$ver.tgz
  curl -sf -u "$NXA" -o "$f" "$url" || { fail=$((fail+1)); printf '%s-%s\tDOWNLOAD_FAIL\n' "$name" "$ver" >> $WORK/helm-result.tsv; continue; }
  got=$(shasum -a 256 "$f" | cut -c1-64); [ -n "$sha" ] && [ "$got" != "$sha" ] && { fail=$((fail+1)); printf '%s-%s\tSHA_MISMATCH_SRC\n' "$name" "$ver" >> $WORK/helm-result.tsv; continue; }
  if out=$(helm push "$f" "oci://$HB_REG/$HB_CHART_PROJECT" $HELM_HTTP 2>&1); then
    dg=$(echo "$out" | grep -o 'Digest: sha256:[0-9a-f]*' | cut -d: -f3 | cut -c1-12); ok=$((ok+1)); r="OK oci-digest=$dg"
  else fail=$((fail+1)); r="PUSH_FAIL $(echo "$out" | tail -1 | cut -c1-120)"; fi
  printf '%s-%s\t%s\ttgz=%s\n' "$name" "$ver" "$r" "${got:0:12}" >> $WORK/helm-result.tsv
done < $WORK/helm.lst
log "helm 결과: push $ok / 건너뜀 $skip / 실패 $fail"; sed 's/^/  /' $WORK/helm-result.tsv | tee -a $OUT
