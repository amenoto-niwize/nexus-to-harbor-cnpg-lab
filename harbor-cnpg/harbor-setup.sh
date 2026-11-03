#!/bin/bash
# Harbor 초기 구성: 프로젝트 2개 + 이관/CI 용 시스템 로봇 계정
set -uo pipefail
H=http://172.16.141.11:30004
S=/private/tmp/claude-502/-Users-isangmin-Desktop-k8s-core/15083b2b-daf4-4c3e-9697-806fdbc7b2e3/scratchpad
HA="admin:$(cat $S/hc.admin)"
OUT=~/nexus-lab/logs/harbor-cnpg/setup.txt; : > $OUT
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }

for p in dlops charts; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -u "$HA" -X POST "$H/api/v2.0/projects" -H 'Content-Type: application/json' \
      -d "{\"project_name\":\"$p\",\"public\":false}")
  log "프로젝트 $p → $c (201=생성, 409=이미 있음)"
done

# 시스템 로봇: 두 프로젝트에 이미지 push/pull + 차트 업로드/조회
body=$(cat <<'JSON'
{"name":"migrator","description":"Nexus→Harbor 이관 및 CI","duration":-1,"level":"system","disable":false,
 "permissions":[
  {"kind":"project","namespace":"dlops","access":[
     {"resource":"repository","action":"pull"},{"resource":"repository","action":"push"},
     {"resource":"artifact","action":"read"},{"resource":"tag","action":"create"},{"resource":"tag","action":"list"}]},
  {"kind":"project","namespace":"charts","access":[
     {"resource":"helm-chart","action":"read"},
     {"resource":"helm-chart-version","action":"create"},{"resource":"helm-chart-version","action":"read"},
     {"resource":"repository","action":"pull"}]}
 ]}
JSON
)
resp=$(curl -s -u "$HA" -X POST "$H/api/v2.0/robots" -H 'Content-Type: application/json' -d "$body")
name=$(echo "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("name",""))' 2>/dev/null)
secret=$(echo "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("secret",""))' 2>/dev/null)
if [ -n "$secret" ]; then
  printf "ROBOT_NAME='%s'\nROBOT_SECRET='%s'\n" "$name" "$secret" > $S/hc.robot; chmod 600 $S/hc.robot
  log "로봇 생성: $name (secret 은 scratchpad/hc.robot 에만 저장)"
else
  log "로봇 생성 응답: $(echo "$resp" | cut -c1-200)"
fi
log "프로젝트 목록: $(curl -s -u "$HA" "$H/api/v2.0/projects" | python3 -c 'import sys,json;print([(p["name"],p["metadata"].get("public")) for p in json.load(sys.stdin)])')"
