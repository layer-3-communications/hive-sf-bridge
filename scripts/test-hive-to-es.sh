#!/bin/bash
set -e

if [ -z "$HIVE_APIKEY" ]; then
  echo -n "Hive API key:"
  read -s HIVE_APIKEY
  echo
fi
if [ -z "$ES_PASS" ]; then
  echo -n "ES password:"
  read -s ES_PASS
  echo
fi

hiveDomain=hive.noc.layer3com.com
hiveIp=192.168.125.251:443
hiveAuth="Authorization: Bearer $HIVE_APIKEY"
# ES_DOMAIN=es-coordinating.noc.layer3com.com:9200
ES_DOMAIN=es.noc.layer3com.com # a tmp setup that relies on /etc/hosts to set this to 192.168.124.10; it'll be
# curl -k -v "https://${hiveIp}/api/case/3356" -H "$hiveAuth"

# curl -k "https://$hiveDomain/api/case/$1" -H "$hiveAuth"

# curl -k "https://$hiveDomain/api/alert/~473796688" -H "$hiveAuth"
# exit 0

# case_hiveid="$(curl -k "https://$hiveDomain/api/case/$1" -H "$hiveAuth" | jq -r .id)"
# curl -k -XPOST "https://$hiveIp/api/v1/query?name=get-case-alerts${case_hiveid}" \
#   -H "$hiveAuth" \
#   -H 'Content-Type: application/json;charset=utf-8' \
#   -d'{"query":[{"_name":"getCase","idOrName":"'"$case_hiveid"'"},{"_name":"alerts"}]}'
# exit 0


# get a case
case_hiveid="$(curl -k "https://$hiveDomain/api/case/$1" -H "$hiveAuth" | jq -r .id)"
echo >&2 "hive case id: $case_hiveid"
# search for alerts
while read alert_hiveid; do
  alertjson="$(curl -k "https://$hiveDomain/api/alert/$alert_hiveid" -H "$hiveAuth")"
  # echo "$alertjson" ; exit 0 # DEBUG
  custId="$(echo "$alertjson" | jq -r .customFields.customer.string)"
  day="$(echo "$alertjson" | jq -r .customFields.timestamp.string | sed s/T.*$//)"
  urlpath="/store-${custId}-${day}d/_doc/$(echo "$alertjson" | jq -r .sourceRef)"
  echo >&2 "urlpath: ${urlpath}"
  # for each one, get the info from ES
  curl -k "https://hive:${ES_PASS}@${ES_DOMAIN}${urlpath}"
  #test urlpath=/store-3007-2021-02-08d/_doc/21FxC5hjhTzPyLy2ivL4zB
done < <(curl -k -XPOST "https://$hiveIp/api/v1/query?name=get-case-alerts${case_hiveid}" \
  -H "$hiveAuth" \
  -H 'Content-Type: application/json;charset=utf-8' \
  -d'{"query":[{"_name":"getCase","idOrName":"'"$case_hiveid"'"},{"_name":"alerts"}]}' \
  | jq -r '.[]._id')
