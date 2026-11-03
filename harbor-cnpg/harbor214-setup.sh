#!/bin/bash
# Harbor 2.14 초기 구성: 프로젝트 2개 + 시스템 로봇. ChartMuseum 이 없으므로 차트도 OCI 아티팩트 → 권한은 이미지와 동일(repository pull/push)
set -uo pipefail
H=${H:-http://172.16.141.11:30004}
S=/private/tmp/claude-502/-Users-isangmin-Desktop-k8s-core/15083b2b-daf4-4c3e-9697-806fdbc7b2e3/scratchpad
HA="admin:$(cat $S/hc.admin)"
OUT=~/nexus-lab/logs/harbor-cnpg/setup214.txt; : > $OUT
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
log "Harbor 버전: $(curl -s -u "$HA" $H/api/v2.0/systeminfo | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("harbor_version"), "| chartmuseum:", d.get("with_chartmuseum"))')"
for p in dlops charts; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -u "$HA" -X POST "$H/api/v2.0/projects" -H 'Content-Type: application/json' -d "{\"project_name\":\"$p\",\"public\":false}")
  log "프로젝트 $p → $c"
done
body='{"name":"migrator","description":"Nexus→Harbor 이관 및 CI","duration":-1,"level":"system","disable":false,
 "permissions":[
  {"kind":"project","namespace":"dlops","access":[
     {"resource":"repository","action":"pull"},{"resource":"repository","action":"push"},
     {"resource":"artifact","action":"read"},{"resource":"artifact","action":"list"},
     {"resource":"tag","action":"create"},{"resource":"tag","action":"list"}]},
  {"kind":"project","namespace":"charts","access":[
     {"resource":"repository","action":"pull"},{"resource":"repository","action":"push"},
     {"resource":"artifact","action":"read"},{"resource":"artifact","action":"list"},
     {"resource":"tag","action":"create"},{"resource":"tag","action":"list"}]}
 ]}'
resp=$(curl -s -u "$HA" -X POST "$H/api/v2.0/robots" -H 'Content-Type: application/json' -d "$body")
name=$(echo "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("name",""))' 2>/dev/null)
secret=$(echo "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("secret",""))' 2>/dev/null)
if [ -n "$secret" ]; then
  printf "ROBOT_NAME='%s'\nROBOT_SECRET='%s'\n" "$name" "$secret" > $S/hc.robot214; chmod 600 $S/hc.robot214   # 이름에 $ 포함 → 작은따옴표 필수
  log "로봇 생성: $name (비밀값은 scratchpad/hc.robot214)"
else log "로봇 생성 응답: $(echo "$resp" | cut -c1-200)"; fi
log "프로젝트: $(curl -s -u "$HA" "$H/api/v2.0/projects" | python3 -c 'import sys,json;print([p["name"] for p in json.load(sys.stdin)])')"
