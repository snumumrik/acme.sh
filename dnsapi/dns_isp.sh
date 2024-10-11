#!/usr/bin/env sh
# shellcheck disable=SC2034
dns_isp_info='ISPsystem
Site: https://www.ispsystem.com/dnsmanager
Options:
 ISP_Url Url to DNSManager
 ISP_Username Username
 ISP_Password Password
'
# todo auth by 'key'
# test: ./acme.sh --staging --dns dns_isp --issue --debug 2 -d example.com -d "*.example.com"
dns_isp_add() {
  fulldomain=$1
  txtvalue=$2

  ISP_Url="${ISP_Url:-$(_readaccountconf_mutable ISP_Url)}"
  ISP_Username="${ISP_Username:-$(_readaccountconf_mutable ISP_Username)}"
  ISP_Password="${ISP_Password:-$(_readaccountconf_mutable ISP_Password)}"

  if [ -z "$ISP_Url" ] || [ -z "$ISP_Username" ] || [ -z "$ISP_Password" ]; then
    _debug2  "$ISP_Url"
    ISP_Url=""
    ISP_Username=""
    ISP_Password=""
    _err "You didn't specify ISP credentials yet."
    return 1
  fi
  if ! _auth "$ISP_Username" "$ISP_Password"; then
    # todo store auth id
    _err "Bad ISP credentials, use one for DNSManager, not BillManager"
    return 1
  fi
  _saveaccountconf_mutable ISP_Url "$ISP_Url"
  _saveaccountconf_mutable ISP_Username "$ISP_Username"
  _saveaccountconf_mutable ISP_Password "$ISP_Password"

  _debug "First detect the root zone"
  if ! _get_root "$fulldomain"; then
    _err "invalid domain"
    return 1
  fi
  _debug2 root_zone "$root_zone"
  _debug2 subdomain "$subdomain"

  _info "Adding record"
  if _isp_rest "domain.record.edit" "name=$subdomain&plid=$root_zone&rtype=txt&ttl=120&value=$txtvalue&caa_flags=0&caa_tag=issue&sok=ok" "JSONdata"; then
    # todo verify result
    if _contains "$response" "$txtvalue"; then
      _info "Added, OK"
      return 0
    fi
  fi
  return 1
}

dns_isp_rm() {
  fulldomain=$1
  txtvalue=$2
  ISP_Url="${ISP_Url:-$(_readaccountconf_mutable ISP_Url)}"
  ISP_Username="${ISP_Username:-$(_readaccountconf_mutable ISP_Username)}"
  ISP_Password="${ISP_Password:-$(_readaccountconf_mutable ISP_Password)}"

  if ! _auth "$ISP_Username" "$ISP_Password"; then
    _err "Bad ISP credentials, use one for DNSManager, not BillManager"
    return 1
  fi
  _debug "First detect the root zone"
  if ! _get_root "$fulldomain"; then
    _err "invalid domain"
    return 1
  fi
  _debug2 root_zone "$root_zone"
  _debug2 subdomain "$subdomain"

  _debug "Getting txt records"
  if ! _isp_rest "domain.record" "elid=$root_zone" "xml"; then
    _err "Error: $response"
    return 1
  fi
  record_key=$(echo "$response" | sed 's/<\/elem><elem>/\n/g' |
    grep "<value>$txtvalue</value>" | grep "<name>$fulldomain\.</name>" | sed 's/></\n/g' | grep 'rkey>.*<\/rkey' | cut -f2 -d'>' | cut -f1 -d'<')
  if [ -z "$record_key" ]; then
    _info "no records to delete"
    _debug2 fulldomain "$1"
    _debug2 txtvalue "$2"
    return 0
  fi
  _info "Remove dns record"
  if ! _isp_rest "domain.record.delete" "elid=$(echo "$record_key" | tr -d '\n' | _url_encode)&plid=$root_zone" "json"; then
    _err "Delete record error."
    return 1;
  fi
  # todo get records again and check existence because domain.record.delete is always ok
  return 0
}

_get_root() {
  domain=$1
  # list domains
  if ! _isp_rest "domain" "" "text"; then
    return 1
  else
    for z in $(echo "$response" | cut -f7 -d' ' | cut -f2 -d'='); do
      _debug2 zone "$z";
      if [ "$(echo "$domain" | _egrep_o ".*\.$z$")" ]; then
        root_zone=$z;
        subdomain=${domain%".$z"}
        return 0
      fi
    done;
    err "root zone for $domain not found"
    return 1
  fi
}
_auth() {
  username="$1"
  password="$2"
  if ! _isp_rest "auth" "username=$username&password=$password" "json"; then
    return 1
  else
    auth=$(echo "$response" | _egrep_o "\"\\\$id\":\s*\"[^\"]*\"" | _head_n 1 | cut -d : -f 2 | tr -d \" | tr -d " ")
    _debug2 "auth" "$auth"
    if [ -z "$auth" ]; then
      return 1
    fi
  fi
}
_isp_rest() {
  fn="$1"
  params="$2"
  out="$3"
  ep='dnsmgr'
  response="$(_get "$ISP_Url$ep?out=$out&func=$fn&$params&auth=$auth")"

  if [ "$?" != "0" ]; then
    _err "error $ep"
    return 1
  fi
  _debug2 response "$response"
  if _contains "$response" "\"error":\{\" || _contains "$response" "ERROR" || _contains "$response" "<error type="; then
    return 1
  fi
  return 0
}