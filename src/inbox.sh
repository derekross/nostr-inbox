id=$1
# Prints the nostr inbox of $id (npub, nprofile, hex or NIP-05) as one line of JSON.
[ -z "$id" ] && { echo null; exit 0; }
umask 077
# A work dir, removed on exit or when killed by the widget timeout; ones left by a hard kill go after an hour.
find /tmp -maxdepth 3 -path "/tmp/nostr-inbox.*" -mmin +60 -delete 2> /dev/null
t=$(mktemp -d /tmp/nostr-inbox.XXXXXX)
trap "rm -f $t/*/* $t/* 2> /dev/null; rmdir $t/* $t 2> /dev/null" EXIT
trap "exit 1" INT TERM
c=~/.cache/nostr-inbox; mkdir -p $c
hex() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
# q relay filters secs: the EVENT lines one relay sends before EOSE.
q() { { printf "[\"REQ\",\"w\",%s]\n" "$2"; sleep $3; } | timeout $(($3 + 2)) websocat -E "$1" 2>/dev/null | awk "/^.\"EOSE/{exit} /^.\"EVENT/{print}"; }
# qa filters secs relays...: q on every relay at once; their well-formed events, deduplicated, as one JSON list.
qa() {
  local f=$1 s=$2 i=0 r d; shift 2; d=$(mktemp -d -p $t)
  for r in "$@"; do q "$r" "$f" $s > $d/$i & i=$((i + 1)); done; wait
  cat $d/* 2>/dev/null | jq -sc "map(.[2] | select(type == \"object\" and (.id | strings | test(\"^[0-9a-f]{64}$\")) and (.pubkey | strings | test(\"^[0-9a-f]{64}$\")) and (.created_at | numbers) and (.kind | numbers) and (.tags | arrays))) | unique_by(.id)"
  rm -f $d/*; rmdir $d
}
# vf file kinds: drops events of these kinds whose id or signature is wrong (when nak is installed).
vf() {
  command -v nak > /dev/null || return 0
  local e
  jq -c --argjson k "$2" ".[] | select(.kind | IN(\$k[]))" $1 | while read -r e; do printf "%s\n" "$e" | nak verify > /dev/null 2>&1 && printf "%s\n" "$e"; done | jq -sc . > $1.ok
  jq -c --argjson k "$2" --slurpfile ok $1.ok "map(select(.kind | IN(\$k[]) | not)) + \$ok[0]" $1 > $1.new && mv $1.new $1; rm -f $1.ok
}
boot="wss://purplepag.es wss://relay.damus.io wss://nos.lol wss://relay.primal.net"

case $id in
  npub1* | nprofile1*)
    if command -v nak > /dev/null; then
      pk=$(cat "$c/id-$id" 2>/dev/null) && hex "$pk" || { pk=$(nak decode "$id" < /dev/null 2>/dev/null | jq -rR "fromjson? // . | if type == \"object\" then .pubkey else . end"); hex "$pk" && printf %s "$pk" > "$c/id-$id"; }
    else
      pk=$(printf %s "$id" | jq -Rr --arg cs qpzry9x8gf2tvdw0s3jn54khce6mua7l -f <(cat <<"JQ"
      def hex: . as $n | "0123456789abcdef" as $h | $h[($n / 16 | floor):($n / 16 | floor) + 1] + $h[($n % 16):($n % 16) + 1];
      (if startswith("nprofile") then 2 else 0 end) as $skip
      | split("1") | last | .[0:-6] | split("")
      | [.[] as $ch | $cs | index($ch)]
      | map([range(4; -1; -1) as $i | (. / pow(2; $i) | floor) % 2]) | flatten
      | . as $b | [range(0; length / 8 | floor) | $b[. * 8:. * 8 + 8] | reduce .[] as $x (0; . * 2 + $x)]
      | .[$skip:$skip + 32] | map(hex) | join("")
JQ
      ))
    fi ;;
  *.*)
    # NIP-05, remembered so a failed lookup does not lose the account.
    name=${id%@*}; dom=${id#*@}; [ "$name" = "$id" ] && name=_
    pk=$(curl -sf -m 8 "https://$dom/.well-known/nostr.json?name=$name" | jq -r --arg n "$name" ".names // {} | with_entries(.key |= ascii_downcase) | .[\$n] | strings | ascii_downcase")
    if hex "$pk"; then printf %s "$pk" > "$c/nip05-$id"; else pk=$(cat "$c/nip05-$id" 2>/dev/null); fi ;;
  *) pk=$id ;;
esac
if ! hex "$pk"; then
  jq -nc --arg id "$id" "{error: (if (\$id | contains(\".\")) then \"no nostr user at \" + \$id else \"not a valid npub\" end)}"
  exit 0
fi

# The profile and relay list (NIP-65), cached for a day once found.
if [ -n "$(find $c/$pk.json -mmin -1440 2>/dev/null)" ]; then
  me=$(cat $c/$pk.json)
else
  qa "{\"kinds\":[0,10002],\"authors\":[\"$pk\"]}" 4 $boot > $t/me.json
  vf $t/me.json "[0,10002]"
  me=$(jq -c --arg pk "$pk" "
    map(select(.pubkey == \$pk)) as \$ev
    | (\$ev | map(select(.kind == 0)) | max_by(.created_at) | .content | strings | fromjson? | objects) as \$p
    | (\$ev | map(select(.kind == 10002)) | max_by(.created_at) | .tags // [] | map(select(.[0] == \"r\" and (.[1] | strings | startswith(\"wss://\"))))) as \$r
    | {name: ([\$p.display_name, \$p.name] | map(strings | select(. != \"\")) | first),
       relays: [\$r[] | select(.[2] == null or .[2] == \"read\") | .[1] | rtrimstr(\"/\")] | .[0:4],
       outbox: [\$r[] | select(.[2] == null or .[2] == \"write\") | .[1] | rtrimstr(\"/\")] | .[0:4]}" $t/me.json)
  printf %s "$me" | jq -e ".name != null or (.relays | length) > 0" > /dev/null 2>&1 && printf %s "$me" > $c/$pk.json
fi
[ -z "$me" ] && me="{}"
# Their own relays first, then well-connected defaults; order kept, duplicates dropped.
pick() { printf %s "$me" | jq -r "$1 + [\"wss://relay.damus.io\", \"wss://nos.lol\", \"wss://relay.primal.net\"] | reduce .[] as \$r ([]; if index([\$r]) then . else . + [\$r] end) | .[0:6] | .[]"; }
inbox=$(pick "(.relays // [])"); outbox=$(pick "(.outbox // [])")

# Zaps, replies, mentions, reposts and reactions tagging the user, last 7 days, and the mute list (NIP-51).
since=$(($(date +%s) - 7 * 86400))
p="\"#p\":[\"$pk\"],\"since\":$since"
qa "{\"kinds\":[9735],$p,\"limit\":100},{\"kinds\":[1],$p,\"limit\":100},{\"kinds\":[7],$p,\"limit\":100},{\"kinds\":[6,16],$p,\"limit\":100}" 6 $inbox > $t/ev.json &
qa "{\"kinds\":[10000],\"authors\":[\"$pk\"]}" 4 $outbox > $t/ml.json &
wait
# Only a mute list newer than the one kept is checked (nak is slow to start on a phone).
jq -c --argjson after "$(jq ".created_at // 0" $c/$pk.mutelist.json 2>/dev/null || echo 0)" "map(select(.created_at > \$after))" $t/ml.json > $t/ml.new && mv $t/ml.new $t/ml.json
vf $t/ml.json "[10000]"

# The newest mute list seen so far is kept, so a relay that fails or lags never brings back an older one.
jq -c --arg pk "$pk" --slurpfile old <(cat $c/$pk.mutelist.json 2>/dev/null || echo null) "map(select(.kind == 10000 and .pubkey == \$pk)) + [\$old[0] | objects] | max_by(.created_at) // empty" $t/ml.json > $t/ml1.json
if [ -s $t/ml1.json ]; then mv $t/ml1.json $c/$pk.mutelist.json; fi
mid=$(jq -r ".id | strings" $c/$pk.mutelist.json 2>/dev/null)
hex "$mid" || mid=""
# Private mutes: Amber (NIP-46) decrypts this version of the list; the ciphertext is kept in a file named by its id,
# so it never becomes part of a command. Decryptions of older versions are removed.
pf=/dev/null
if [ -n "$mid" ]; then
  jq -r ".content // empty" $c/$pk.mutelist.json > $c/$pk.$mid.cipher
  for f in $c/$pk.*.mutes.json $c/$pk.*.cipher; do case $f in "$c/$pk.$mid".*) ;; *) rm -f "$f" ;; esac; done
  [ -s $c/$pk.$mid.mutes.json ] && pf=$c/$pk.$mid.mutes.json
fi
# NIP-46: a client key and secret for pairing with the signer, made only when there are private mutes to decrypt.
k=~/.config/nostr-inbox; connect=""
if command -v nak > /dev/null && [ -s "$c/$pk.$mid.cipher" ]; then
  mkdir -p $k
  [ -s $k/client.key ] || nak key generate > $k/client.key
  [ -s $k/connect.secret ] || nak key generate | cut -c1-16 > $k/connect.secret
  [ -s $k/client.pub ] || nak key public $(cat $k/client.key) > $k/client.pub
  [ -s $k/relays ] || echo wss://relay.nip46.com wss://bucket.coracle.social wss://nrs.primal.net > $k/relays
  connect="nostrconnect://$(cat $k/client.pub)?$(for r in $(cat $k/relays); do printf "relay=%s&" $(printf %s $r | jq -Rr @uri); done)secret=$(cat $k/connect.secret)&perms=nip44_decrypt%2Cnip04_decrypt&name=nostr%20inbox"
fi
jq -c --arg pk "$pk" --slurpfile priv "$pf" --slurpfile ml <(cat $c/$pk.mutelist.json 2>/dev/null || echo null) --arg mid "$mid" --arg nak "$(command -v nak)" --arg bunker "$([ -s $k/bunker ] && echo yes)" --arg connect "$connect" -f <(cat <<"JQ"
  def tag($k): [.tags[]? | select(type == "array" and .[0] == $k) | .[1] | strings];
  def sats(b): (b // "" | capture("^lnbc(?<n>[0-9]+)(?<m>[munp]?)1")? // null) as $c
    | if $c == null then null else ($c.n | tonumber) * ({"m": 100000, "u": 100, "n": 0.1, "p": 0.0001, "": 100000000}[$c.m]) | floor end;
  ($ml[0] | objects) as $list
  | ($priv[0] | if type == "array" then map(arrays) else null end) as $pt
  | (($list.tags // []) + ($pt // [])) as $mute
  | ({tags: $mute} | [tag("p"), tag("e"), (tag("t") | map(ascii_downcase)), (tag("word") | map(ascii_downcase | select(. != "")))]) as [$mp, $me, $mt, $mw]
  | map(select(.pubkey != $pk or .kind == 9735))
  | map(select((any(tag("e")[]; IN($me[])) | not) and (any(tag("t")[] | ascii_downcase; IN($mt[])) | not)))
  | map(
    ((.content | strings) // "") as $text
    | if .kind == 9735 then
      (tag("description")[0] | fromjson? | objects // {}) as $z
      | {id, at: .created_at, type: "zap", who: ($z.pubkey | strings | select(test("^[0-9a-f]{64}$"))) // .pubkey,
         text: (($z.content | strings) // "")[0:200], ref: ((tag("e") | last) // .id), mine: true,
         sats: (sats(tag("bolt11")[0]) // ((($z | tag("amount")[0] | tonumber?) // null) | if . then ./1000 | floor else null end))}
    elif .kind == 1 then {id, at: .created_at, type: (if (tag("e") | length) > 0 then "reply" else "mention" end), who: .pubkey, text: $text[0:400], ref: .id, mine: true}
    elif .kind == 7 then {id, at: .created_at, type: "reaction", who: .pubkey, text: $text[0:40], ref: ((tag("e") | last) // .id), mine: ((tag("p") | last) == $pk)}
    else {id, at: .created_at, type: "repost", who: .pubkey, text: "", ref: ((tag("e") | last) // .id), mine: ((tag("p") | last) == $pk)} end)
  | map(select((.who | IN($mp[]) | not) and ((.text | ascii_downcase) as $c | any($mw[]; . as $w | $c | contains($w)) | not)))
  | {mutes: {id: (if $mid == "" then null else $mid end), private: (if (($list.content | strings) // "") == "" then null elif $pt == null then -1 else ($pt | length) end),
      nip04: ((($list.content | strings) // "") | contains("?iv=")), nak: ($nak != ""), bunker: ($bunker == "yes"), connect: (if $connect == "" then null else $connect end)},
    items: (group_by(.type) | map(sort_by(-.at) | .[0:100]) | add // [] | sort_by(-.at))}
JQ
) $t/ev.json > $t/items.json

# NIP-21 links (nostr:nevent1…) so taps open in the phone nostr app; njump.me if nak is missing.
if command -v nak > /dev/null; then jq -c --arg pk "$pk" ".items[] | {id: .ref, pubkey: (if .type == \"reply\" or .type == \"mention\" then .who else \$pk end)}" $t/items.json | nak encode nevent 2> /dev/null | jq -Rsc "split(\"\n\") | map(select(. != \"\"))" > $t/nev.json; fi
[ -s $t/nev.json ] || echo "[]" > $t/nev.json

# Names of the people in it.
f=$(jq -r ".items | map(.who) | unique | .[0:200] | . as \$a | [range(0; length; 20) | {kinds: [0], authors: \$a[.:. + 20], limit: 100} | tojson] | join(\",\")" $t/items.json)
if [ -n "$f" ]; then qa "$f" 5 wss://purplepag.es wss://relay.ditto.pub wss://relay.primal.net wss://nos.lol > $t/names.json; else echo "[]" > $t/names.json; fi
jq -nc --arg pk "$pk" --argjson me "$me" --slurpfile items $t/items.json --slurpfile ps $t/names.json --slurpfile nev $t/nev.json -f <(cat <<"JQ"
  ($ps[0] | group_by(.pubkey) | map(max_by(.created_at) | {key: .pubkey, value: (.content | strings | fromjson? | objects | [.display_name, .name] | map(strings | select(. != "")) | first)}) | from_entries) as $names
  | {pk: $pk, name: $me.name, relays: $me.relays, at: now | floor, mutes: $items[0].mutes,
     items: ($items[0].items | (length == ($nev[0] | length)) as $ok | to_entries | map(.value + {name: ($names[.value.who] // ("…" + .value.who[-8:])), nevent: (if $ok then $nev[0][.key] else null end)}))}
JQ
)
