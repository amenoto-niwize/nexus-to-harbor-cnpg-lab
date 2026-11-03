#!/bin/bash
# CNPG(단일 인스턴스) 파드 재시작 시 Harbor 영향 측정: pull / 관리 API / push 를 1초 간격으로
# 인자: $1 = 라벨
set -uo pipefail
export KUBECONFIG=/private/tmp/claude-502/-Users-isangmin-Desktop-k8s-core/15083b2b-daf4-4c3e-9697-806fdbc7b2e3/scratchpad/kubeconfig
S=/private/tmp/claude-502/-Users-isangmin-Desktop-k8s-core/15083b2b-daf4-4c3e-9697-806fdbc7b2e3/scratchpad
. $S/hc.robot; HA="admin:$(cat $S/hc.admin)"; RA="$ROBOT_NAME:$ROBOT_SECRET"; H=http://172.16.141.11:30004
OUT=~/nexus-lab/logs/harbor-cnpg/ops.txt; P=$S/pgr-$1; rm -rf $P; mkdir -p $P; touch $P/run
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
( n=0; while [ -e $P/run ]; do n=$((n+1)); t=$(date +%H:%M:%S)
    m=$(curl -s -m 4 -o /dev/null -w '%{http_code}' -u "$RA" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' $H/v2/dlops/app1/manifests/1.1)
    a=$(curl -s -m 4 -o /dev/null -w '%{http_code}' -u "$HA" "$H/api/v2.0/projects/dlops/repositories?page_size=5")
    w=$(timeout 8 skopeo copy -q --src-tls-verify=false --dest-tls-verify=false --src-creds "$RA" --dest-creds "$RA" docker://172.16.141.11:30004/dlops/app1:1.1 docker://172.16.141.11:30004/dlops/probe:$1-$n >/dev/null 2>&1 && echo ok || echo fail)
    echo "$t pull=$m api=$a push=$w" >> $P/probe.log; sleep 1; done ) &
sleep 6
log "===== [$1] CNPG 파드 삭제"; T0=$(date +%s); kubectl -n harbor-cnpg delete pod harbor-pg-1 --wait=false >/dev/null
gone=""; for i in $(seq 1 400); do sleep 1
  st=$(kubectl -n harbor-cnpg get pod harbor-pg-1 -o jsonpath='{.metadata.deletionTimestamp}|{.status.containerStatuses[0].ready}' 2>/dev/null)
  case "$st" in "|true") [ -n "$gone" ] && break;; ""|"|false"|"|") [ -z "$gone" ] && gone=$(( $(date +%s)-T0 ));; esac
done
T1=$(( $(date +%s)-T0 ))
log "[$1] 옛 파드 종료까지 ${gone:-?}s, 새 파드 ready 까지 ${T1}s"
sleep 15; rm -f $P/run; sleep 9
log "[$1] 타임라인(같은 상태 묶음: 횟수 시작시각 상태)"; awk '{print $1, $2, $3, $4}' $P/probe.log | uniq -f1 -c | sed 's/^/  /' | tee -a $OUT
python3 - $P/probe.log <<'EOF' | tee -a ~/nexus-lab/logs/harbor-cnpg/ops.txt
import sys
rows=[dict([("t",l.split()[0])]+[x.split("=") for x in l.split()[1:]]) for l in open(sys.argv[1])]
for k,good in (("pull","200"),("api","200"),("push","ok")):
    bad=[r["t"] for r in rows if r[k]!=good]
    print(f"  {k:5s} 실패 {len(bad):3d}/{len(rows)}" + (f"  ({bad[0]} ~ {bad[-1]})" if bad else ""))
EOF
