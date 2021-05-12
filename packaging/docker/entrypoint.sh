#!/bin/bash

ACTION="${1:-run}"
CHAINID="${CLEF_CHAINID:-12345}"
DATA_DIR=/app/data
IP="${CLEF_IP:-0.0.0.0}"
PORT="${CLEF_PORT:-8550}"
VAULT_SECRETS_DATA="${VAULT_SECRETS_ENGINE}"/data/"${VAULT_SECRETS_DIR}"
VAULT_SECRETS_METADATA="${VAULT_SECRETS_ENGINE}"/metadata/"${VAULT_SECRETS_DIR}"
VAULT_DEBUG="${VAULT_DEBUG:-false}"

init() {
    parse_json() { echo "$1"|sed -e 's/[{}]/''/g'|sed -e 's/", "/'\",\"'/g'|sed -e 's/" ,"/'\",\"'/g'|sed -e 's/" , "/'\",\"'/g'|sed -e 's/","/'\"---SEPERATOR---\"'/g'|awk -F=':' -v RS='---SEPERATOR---' "\$1~/\"$2\"/ {print}"|sed -e "s/\"$2\"://"|tr -d "\n\t"|sed -e 's/\\"/"/g'|sed -e 's/\\\\/\\/g'|sed -e 's/^[ \t]*//g'|sed -e 's/^"//' -e 's/"$//' ; }
    if [ ! -f "$DATA_DIR"/password ]; then
        < /dev/urandom tr -dc _A-Z-a-z-0-9 2> /dev/null | head -c32 > "$DATA_DIR"/password
    fi
    SECRET=$(cat "$DATA_DIR"/password)
    /usr/local/bin/clef --configdir "$DATA_DIR" --stdio-ui init >/dev/null 2>&1 << EOF
$SECRET
$SECRET
EOF
    if [ "$(ls -A "$DATA_DIR"/keystore 2> /dev/null)" = "" ]; then
        /usr/local/bin/clef --keystore "$DATA_DIR"/keystore --stdio-ui newaccount --lightkdf >/dev/null 2>&1 << EOF
$SECRET
EOF
    fi
    /usr/local/bin/clef --keystore "$DATA_DIR"/keystore --configdir "$DATA_DIR" --stdio-ui setpw 0x"$(parse_json "$(cat "$DATA_DIR"/keystore/*)" address)" >/dev/null 2>&1 << EOF
$SECRET
$SECRET
$SECRET
EOF
    /usr/local/bin/clef --keystore "$DATA_DIR"/keystore --configdir "$DATA_DIR" --stdio-ui attest "$(sha256sum /app/config/rules.js | cut -d' ' -f1 | tr -d '\n')" >/dev/null 2>&1 << EOF
$SECRET
EOF
}

vault_download() {
    if [ ! -f "$DATA_DIR"/masterseed.json ]; then
        if [ "$VAULT_DEBUG" ]; then >&2 echo "Downloading masterseed.json from $VAULT_SECRETS_DATA/masterseed"; fi
        curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_SECRETS_DATA"/masterseed | jq -c .data.data > "$DATA_DIR"/masterseed.json;
        chmod 400 "$DATA_DIR"/masterseed.json;
    fi
        
    VAULT_DIR=$(curl --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_SECRETS_DATA"/vault/name | jq -r .data.data.name)
    if [ "$VAULT_DEBUG" ]; then >&2 echo "Clef Vault directory is $VAULT_DIR"; fi
    if [ ! -d "$DATA_DIR"/"$VAULT_DIR" ]; then
        mkdir "$DATA_DIR"/"$VAULT_DIR";
        chmod 700 "$DATA_DIR"/"$VAULT_DIR";
        if [ "$VAULT_DEBUG" ]; then >&2 echo "Downloading config.json from $VAULT_SECRETS_DATA/vault/config"; fi
        curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_SECRETS_DATA"/vault/config | jq -c .data.data > "$DATA_DIR"/"$VAULT_DIR"/config.json;
        chmod 600 "$DATA_DIR"/"$VAULT_DIR"/config.json;
        if [ "$VAULT_DEBUG" ]; then >&2 echo "Downloading credentials.json from $VAULT_SECRETS_DATA/vault/credentials"; fi
        curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_SECRETS_DATA"/vault/credentials | jq -c .data.data > "$DATA_DIR"/"$VAULT_DIR"/credentials.json;
        chmod 600 "$DATA_DIR"/"$VAULT_DIR"/credentials.json;        
    fi

    if [ ! -d "$DATA_DIR"/keystore ]; then
        mkdir "$DATA_DIR/keystore";
        chmod 700 "$DATA_DIR/keystore";
        keyfile="$(curl --header "X-Vault-Token: $VAULT_TOKEN" --request LIST "$VAULT_SECRETS_METADATA"/keystore | jq -rc '.data.keys|.[]')"
        if [ "$VAULT_DEBUG" ]; then >&2 echo "Downloading key $keyfile from $VAULT_SECRETS_DATA/keystore/$keyfile"; fi
        curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_SECRETS_DATA"/keystore/"$keyfile" | jq -rc .data.data > "$DATA_DIR/keystore/$keyfile"
        chmod 600 "$DATA_DIR/keystore/$keyfile"
    fi
}

vault_upload() {
    if [ "$VAULT_DEBUG" ]; then >&2 echo "Uploading masterseed.json to $VAULT_SECRETS_DATA/masterseed using token $VAULT_TOKEN"; fi
    echo "{\"data\":$(cat "$DATA_DIR"/masterseed.json)}" | curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" --data @- --request POST "$VAULT_SECRETS_DATA"/masterseed
    if [ "$VAULT_DEBUG" ]; then >&2 echo "Uploading password to $VAULT_SECRETS_DATA/password using token $VAULT_TOKEN"; fi
    echo "{\"data\":{\"password\":\"$(cat "$DATA_DIR"/password)\"}}" | curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" --data @- --request POST "$VAULT_SECRETS_DATA"/password

    VAULT_DIR=$(find "$DATA_DIR" -regextype sed -regex ".*/[[:xdigit:]]\{20\}" -printf '%P\n')
    if [ "$VAULT_DEBUG" ]; then >&2 echo "Clef Vault dir is $VAULT_DIR"; fi
    if [ "$VAULT_DEBUG" ]; then >&2 echo "Uploading Vault dir name to $VAULT_SECRETS_DATA/vault/name using token $VAULT_TOKEN"; fi
    echo "{\"data\":{\"name\":\"$VAULT_DIR\"}}" | curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" --data @- --request POST "$VAULT_SECRETS_DATA"/vault/name
    if [ "$VAULT_DEBUG" ]; then >&2 echo "Uploading config.json to $VAULT_SECRETS_DATA/vault/config using token $VAULT_TOKEN"; fi
    echo "{\"data\":$(cat "$DATA_DIR"/"$VAULT_DIR"/config.json)}" | curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" --data @- --request POST "$VAULT_SECRETS_DATA"/vault/config
    if [ "$VAULT_DEBUG" ]; then >&2 echo "Uploading credentials.json to $VAULT_SECRETS_DATA/vault/credentials using token $VAULT_TOKEN"; fi
    echo "{\"data\":$(cat "$DATA_DIR"/"$VAULT_DIR"/credentials.json)}" | curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" --data @- --request POST "$VAULT_SECRETS_DATA"/vault/credentials
    
    keyfile="$(find "$DATA_DIR"/keystore -mindepth 1 -maxdepth 1 -printf '%P\n')"
    if [ "$VAULT_DEBUG" ]; then >&2 echo "Uploading key $keyfile to $VAULT_SECRETS_DATA/keystore/$keyfile using token $VAULT_TOKEN"; fi
    echo "{\"data\":$(cat "$DATA_DIR"/keystore/"$keyfile")}" | \
    curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" --data @- --request POST "$VAULT_SECRETS_DATA"/keystore/"$keyfile"
    addr=$(jq -r .address < "$DATA_DIR"/keystore/"$keyfile")
    echo "{\"data\":{\"address\":\"$addr\"}}" | curl --header "X-Vault-Token: $VAULT_TOKEN" --data @- --request POST "$VAULT_SECRETS_DATA"/address
}

run() {
    SECRET=${1:?"Missing password"}
    rm /tmp/stdin /tmp/stdout || true
    mkfifo /tmp/stdin /tmp/stdout
    (
    exec 3>/tmp/stdin
    while read -r < /tmp/stdout
    do
        if [[ "$REPLY" =~ "enter the password" ]]; then
            echo '{ "jsonrpc": "2.0", "id":1, "result": { "text":"'"$SECRET"'" } }' > /tmp/stdin
            break
        fi
    done
    ) &
    /usr/local/bin/clef --stdio-ui --keystore "$DATA_DIR"/keystore --configdir "$DATA_DIR" --chainid "$CHAINID" --http --http.addr "$IP" --http.port "$PORT" --http.vhosts "*" --rules /app/config/rules.js --nousb --lightkdf --ipcdisable --4bytedb-custom /app/config/4byte.json --pcscdpath "" --auditlog "" --loglevel 3 < /tmp/stdin | tee /tmp/stdout
}

full() {
    if [ ! -f "$DATA_DIR"/masterseed.json ]; then
        init
    fi
    run $(cat "$DATA_DIR"/password)
}

vault() {
    if [ ! -f "$DATA_DIR"/masterseed.json ]; then
        if [ "$VAULT_DEBUG" ]; then >&2 echo "masterseed.json not found in $DATA_DIR"; fi;
        if [ "$(curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_SECRETS_DATA"/masterseed)" = '{"errors":[]}' ]; then
            if [ "$VAULT_DEBUG" ]; then >&2 echo "masterseed.json not found in Vault"; fi;
            if [ "$VAULT_DEBUG" ]; then >&2 echo "Initializing Clef"; fi;
            init;
            if [ "$VAULT_DEBUG" ]; then >&2 echo "Uploading key material to Vault"; fi;
            vault_upload;
        else
            if [ "$VAULT_DEBUG" ]; then >&2 echo "Downloading key material from Vault"; fi;
            vault_download;
        fi;
    fi
    run $(curl --retry 20 --retry-connrefused --retry-delay 1 -s --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_SECRETS_DATA"/password | jq -r .data.data.password)
}

$ACTION
