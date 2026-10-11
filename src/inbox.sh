id=$1
# Prints the nostr inbox of $id (npub, nprofile, hex or NIP-05) as one line of JSON.
[ -z "$id" ] && { echo null; exit 0; }
t=$(mktemp -d); trap "rm -f $t/*; rmdir $t" EXIT
c=~/.cache/nostr-inbox; mkdir -p $c
# q relay filter secs: the EVENT lines one relay sends before EOSE.
q() { { printf "[\"REQ\",\"w\",%s]\n" "$2"; sleep $3; } | timeout $(($3 + 2)) websocat -E "$1" 2>/dev/null | awk "/^.\"EOSE/{exit} /^.\"EVENT/{print}"; }
# qa filter secs relays...: q on every relay at once, all their events in one list.
qa() { local f=$1 s=$2 i=0 r; shift 2; for r in "$@"; do q "$r" "$f" $s > $t/q$i & i=$((i + 1)); done; wait; cat $t/q* 2>/dev/null | jq -sc "map(.[2]) | unique_by(.id)"; rm -f $t/q*; }
boot="wss://purplepag.es wss://relay.damus.io wss://nos.lol wss://relay.primal.net"

case $id in
  npub1* | nprofile1*)
    pk=$(printf %s "$id" | jq -Rr --arg cs qpzry9x8gf2tvdw0s3jn54khce6mua7l -f <(cat <<"JQ"
      def hex: . as $n | "0123456789abcdef" as $h | $h[($n / 16 | floor):($n / 16 | floor) + 1] + $h[($n % 16):($n % 16) + 1];
      (if startswith("nprofile") then 2 else 0 end) as $skip
      | split("1") | last | .[0:-6] | split("")
      | [.[] as $ch | $cs | index($ch)]
      | map([range(4; -1; -1) as $i | (. / pow(2; $i) | floor) % 2]) | flatten
      | . as $b | [range(0; length / 8 | floor) | $b[. * 8:. * 8 + 8] | reduce .[] as $x (0; . * 2 + $x)]
      | .[$skip:$skip + 32] | map(hex) | join("")
JQ
    )) ;;
  *.*)
    name=${id%@*}; dom=${id#*@}; [ "$name" = "$id" ] && name=_
    pk=$(curl -sf -m 8 "https://$dom/.well-known/nostr.json?name=$name" | jq -r --arg n "$name" ".names[\$n] // empty") ;;
  *) pk=$id ;;
esac
if ! [[ $pk =~ ^[0-9a-f]{64}$ ]]; then
  jq -nc --arg id "$id" "{error: (if (\$id | contains(\".\")) then \"no nostr user at \" + \$id else \"not a valid npub\" end)}"
  exit 0
fi

# The profile and relay list (NIP-65), cached for a day.
if [ -n "$(find $c/$pk.json -mmin -1440 2>/dev/null)" ]; then
  me=$(cat $c/$pk.json)
else
  me=$(qa "{\"kinds\":[0,10002],\"authors\":[\"$pk\"]}" 4 $boot | jq -c "
    (map(select(.kind == 0)) | max_by(.created_at) | .content | fromjson? // {}) as \$p
    | (map(select(.kind == 10002)) | max_by(.created_at) | .tags // []) as \$r
    | {name: ([\$p.display_name, \$p.name] | map(select(. != null and . != \"\")) | first),
       relays: [\$r[] | select(.[0] == \"r\" and (.[2] == null or .[2] == \"read\")) | .[1] | rtrimstr(\"/\")] | .[0:4]}")
  [ -n "$me" ] && printf %s "$me" > $c/$pk.json
fi
[ -z "$me" ] && me="{}"
relays=$(printf %s "$me" | jq -r "(.relays // []) + [\"wss://relay.damus.io\", \"wss://nos.lol\", \"wss://relay.primal.net\"] | unique | .[0:6] | .[]")

# Zaps, replies, mentions, reposts and reactions tagging the user, last 7 days.
since=$(($(date +%s) - 7 * 86400))
p="\"#p\":[\"$pk\"],\"since\":$since"
qa "{\"kinds\":[9735],$p,\"limit\":100},{\"kinds\":[1],$p,\"limit\":100},{\"kinds\":[6,7,16],$p,\"limit\":100},{\"kinds\":[10000],\"authors\":[\"$pk\"]}" 6 $relays > $t/ev.json
# Private mutes: the signer (Amber, over NIP-46) decrypts this version of the list on request, see the widget.
# The ciphertext goes to a file so it never becomes part of a command.
jq -r --arg pk "$pk" "map(select(.kind == 10000 and .pubkey == \$pk)) | max_by(.created_at) | .content // empty" $t/ev.json > $c/$pk.cipher
mid=$(jq -r --arg pk "$pk" "map(select(.kind == 10000 and .pubkey == \$pk)) | max_by(.created_at) | .id // empty" $t/ev.json)
for f in $c/$pk.*.mutes.json; do [ -f "$f" ] && [ "$f" != "$c/$pk.$mid.mutes.json" ] && rm -f "$f"; done
pf=$c/$pk.$mid.mutes.json; [ -s "$pf" ] || pf=/dev/null
# NIP-46: a fixed client key and secret for this phone, and the nostrconnect:// link that pairs it with the signer.
k=~/.config/nostr-inbox; connect=""
if command -v nak > /dev/null; then
  mkdir -p $k
  [ -s $k/client.key ] || (umask 077; nak key generate > $k/client.key)
  [ -s $k/connect.secret ] || (umask 077; nak key generate | cut -c1-16 > $k/connect.secret)
  [ -s $k/relays ] || echo wss://relay.nip46.com wss://bucket.coracle.social wss://nrs.primal.net > $k/relays  # the NIP-46 relays Opal uses, minus the dead relay.nsec.app
  connect="nostrconnect://$(nak key public $(cat $k/client.key))?$(for r in $(cat $k/relays); do printf "relay=%s&" $(printf %s $r | jq -Rr @uri); done)secret=$(cat $k/connect.secret)&perms=nip44_decrypt%2Cnip04_decrypt&name=nostr%20inbox"
fi
jq -c --arg pk "$pk" --slurpfile priv "$pf" --arg nak "$(command -v nak)" --arg bunker "$([ -s $k/bunker ] && echo yes)" --arg connect "$connect" -f <(cat <<"JQ"
  def tag($k): [.tags[]? | select(.[0] == $k) | .[1]];
  def sats(b): (b // "" | capture("^lnbc(?<n>[0-9]+)(?<m>[munp]?)1")? // null) as $c
    | if $c == null then null else ($c.n | tonumber) * ({"m": 100000, "u": 100, "n": 0.1, "p": 0.0001, "": 100000000}[$c.m]) | floor end;
  # Public NIP-51 mutes (kind 10000): people, threads, hashtags and words. Private ones are encrypted to the user.
  (map(select(.kind == 10000 and .pubkey == $pk)) | max_by(.created_at)) as $ml
  | ($priv[0] | if type == "array" then map(select(type == "array")) else null end) as $pt
  | (($ml.tags // []) + ($pt // [])) as $mute
  | [$mute[] | select(.[0] == "p") | .[1]] as $mp
  | [$mute[] | select(.[0] == "e") | .[1]] as $me
  | [$mute[] | select(.[0] == "t") | .[1] | ascii_downcase] as $mt
  | [$mute[] | select(.[0] == "word") | .[1] | ascii_downcase | select(. != "")] as $mw
  | map(select(.kind != 10000 and (.pubkey != $pk or .kind == 9735))) | length as $total
  | map(select((any(tag("e")[]; IN($me[])) | not) and (any(tag("t")[] | ascii_downcase; IN($mt[])) | not)))
  | map(
    if .kind == 9735 then
      (tag("description")[0] | fromjson? // {}) as $z
      | {id, at: .created_at, type: "zap", who: ($z.pubkey // .pubkey), text: ($z.content // ""), ref: ((tag("e") | last) // .id),
         sats: ((($z | tag("amount")[0] | tonumber?) // null | if . then ./1000 | floor else null end) // sats(tag("bolt11")[0]))}
    elif .kind == 1 then {id, at: .created_at, type: (if (tag("e") | length) > 0 then "reply" else "mention" end), who: .pubkey, text: .content[0:400], ref: .id}
    elif .kind == 7 then {id, at: .created_at, type: "reaction", who: .pubkey, text: .content[0:40], ref: ((tag("e") | last) // .id)}
    else {id, at: .created_at, type: "repost", who: .pubkey, text: "", ref: ((tag("e") | last) // .id)} end)
  | map(select((.who | IN($mp[]) | not) and ((.text | ascii_downcase) as $c | any($mw[]; . as $w | $c | contains($w)) | not)))
  | {mutes: {id: $ml.id, private: (if ($ml.content // "") == "" then null elif $pt == null then -1 else ($pt | length) end),
      nip04: (($ml.content // "") | contains("?iv=")), nak: ($nak != ""), bunker: ($bunker == "yes"), connect: (if $connect == "" then null else $connect end)},
    muted: ($total - length), items: (group_by(.type) | map(sort_by(-.at) | .[0:40]) | add // [] | sort_by(-.at))}
JQ
) $t/ev.json > $t/items.json

# NIP-21 links (nostr:nevent1…) so taps open in the phone nostr app; njump.me if nak is missing.
if command -v nak > /dev/null; then jq -c --arg pk "$pk" ".items[] | {id: .ref, pubkey: (if .type == \"reply\" or .type == \"mention\" then .who else \$pk end)}" $t/items.json | nak encode nevent 2> /dev/null | jq -Rsc "split(\"\n\") | map(select(. != \"\"))" > $t/nev.json; fi
[ -s $t/nev.json ] || echo "[]" > $t/nev.json

# Names of the people in it.
f=$(jq -r ".items | map(.who) | unique | .[0:100] | . as \$a | [range(0; length; 20) | {kinds: [0], authors: \$a[.:. + 20], limit: 100} | tojson] | join(\",\")" $t/items.json)
qa "$f" 5 wss://purplepag.es wss://relay.ditto.pub wss://relay.primal.net wss://nos.lol > $t/names.json
jq -nc --arg pk "$pk" --argjson me "$me" --slurpfile items $t/items.json --slurpfile ps $t/names.json --slurpfile nev $t/nev.json -f <(cat <<"JQ"
  ($ps[0] | group_by(.pubkey) | map(max_by(.created_at) | {key: .pubkey, value: (.content | fromjson? // {} | [.display_name, .name] | map(select(type == "string" and . != "")) | first)}) | from_entries) as $names
  | {pk: $pk, name: $me.name, relays: $me.relays, at: now | floor, muted: $items[0].muted, mutes: $items[0].mutes,
     items: ($items[0].items | (length == ($nev[0] | length)) as $ok | to_entries | map(.value + {name: ($names[.value.who] // ("npub…" + .value.who[-6:])), nevent: (if $ok then $nev[0][.key] else null end)}))}
JQ
)
