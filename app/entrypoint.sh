#!/bin/bash
# shellcheck disable=SC2155

set -u

function check_deprecated_env_var {
    if [[ -n "${ACME_TOS_HASH:-}" ]]; then
        echo "Info: the ACME_TOS_HASH environment variable is no longer used by simp_le and has been deprecated."
        echo "simp_le now implicitly agree to the ACME CA ToS."
    fi
}

function check_docker_socket {
    if [[ $DOCKER_HOST == unix://* ]]; then
        socket_file=${DOCKER_HOST#unix://}
        if [[ ! -S $socket_file ]]; then
            echo "Error: you need to share your Docker host socket with a volume at $socket_file" >&2
            echo "Typically you should run your container with: '-v /var/run/docker.sock:$socket_file:ro'" >&2
            exit 1
        fi
    fi
}

function check_writable_directory {
    local dir="$1"
    docker_api "/containers/${SELF_CID:-$(get_self_cid)}/json" | jq ".Mounts[].Destination" | grep -q "^\"$dir\"$"
    if [[ $? -ne 0 ]]; then
        echo "Warning: '$dir' does not appear to be a mounted volume."
    fi
    if [[ ! -d "$dir" ]]; then
        echo "Error: can't access to '$dir' directory !" >&2
        echo "Check that '$dir' directory is declared as a writable volume." >&2
        exit 1
    fi
    touch $dir/.check_writable 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "Error: can't write to the '$dir' directory !" >&2
        echo "Check that '$dir' directory is export as a writable volume." >&2
        exit 1
    fi
    rm -f $dir/.check_writable
}

function check_dh_group {
    # Credits to Steve Kamerman for the background Diffie-Hellman creation logic.
    # https://github.com/jwilder/nginx-proxy/pull/589
    local DHPARAM_BITS="${DHPARAM_BITS:-2048}"
    re='^[0-9]*$'
    if ! [[ "$DHPARAM_BITS" =~ $re ]] ; then
       echo "Error: invalid Diffie-Hellman size of $DHPARAM_BITS !" >&2
       exit 1
    fi

    # If a dhparam file is not available, use the pre-generated one and generate a new one in the background.
    local PREGEN_DHPARAM_FILE="/app/dhparam.pem.default"
    local DHPARAM_FILE="/etc/nginx/certs/dhparam.pem"
    local GEN_LOCKFILE="/tmp/le_companion_dhparam_generating.lock"

    # The hash of the pregenerated dhparam file is used to check if the pregen dhparam is already in use
    local PREGEN_HASH=$(sha256sum "$PREGEN_DHPARAM_FILE" | cut -d ' ' -f1)
    if [[ -f "$DHPARAM_FILE" ]]; then
        local CURRENT_HASH=$(sha256sum "$DHPARAM_FILE" | cut -d ' ' -f1)
        if [[ "$PREGEN_HASH" != "$CURRENT_HASH" ]]; then
            # There is already a dhparam, and it's not the default
            echo "Info: Custom Diffie-Hellman group found, generation skipped."
            return 0
          fi

        if [[ -f "$GEN_LOCKFILE" ]]; then
            # Generation is already in progress
            return 0
        fi
    fi

    echo "Info: Creating Diffie-Hellman group in the background."
    echo "A pre-generated Diffie-Hellman group will be used for now while the new one
is being created."

    # Put the default dhparam file in place so we can start immediately
    cp "$PREGEN_DHPARAM_FILE" "$DHPARAM_FILE"
    touch "$GEN_LOCKFILE"

    # Generate a new dhparam in the background in a low priority and reload nginx when finished (grep removes the progress indicator).
    (
        (
            nice -n +5 openssl dhparam -out "$DHPARAM_FILE" "$DHPARAM_BITS" 2>&1 \
            && echo "Info: Diffie-Hellman group creation complete, reloading nginx." \
            && reload_nginx
        ) | grep -vE '^[\.+]+'
        rm "$GEN_LOCKFILE"
    ) &disown
}

source /app/functions.sh

[[ $DEBUG == true ]] && set -x

if [[ "$*" == "/bin/bash /app/start.sh" ]]; then
    acmev2_re='https://acme-.*v02\.api\.letsencrypt\.org/directory'
    if [[ "${ACME_CA_URI:-}" =~ $acmev2_re ]]; then
        echo "Error: ACME v2 API is not yet supported by simp_le."
        echo "See https://github.com/zenhack/simp_le/issues/101"
        exit 1
    fi
    check_docker_socket
    if [[ -z "$(get_self_cid)" ]]; then
        echo "Error: can't get my container ID !" >&2
        exit 1
    else
        export SELF_CID="$(get_self_cid)"
    fi
    if [[ -z "$(get_nginx_proxy_container)" ]]; then
        echo "Error: can't get nginx-proxy container ID !" >&2
        echo "Check that you are doing one of the following :" >&2
        echo -e "\t- Use the --volumes-from option to mount volumes from the nginx-proxy container." >&2
        echo -e "\t- Set the NGINX_PROXY_CONTAINER env var on the letsencrypt-companion container to the name of the nginx-proxy container." >&2
        echo -e "\t- Label the nginx-proxy container to use with 'com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy'." >&2
        exit 1
    elif [[ -z "$(get_docker_gen_container)" ]] && ! is_docker_gen_container "$(get_nginx_proxy_container)"; then
        echo "Error: can't get docker-gen container id !" >&2
        echo "If you are running a three containers setup, check that you are doing one of the following :" >&2
        echo -e "\t- Set the NGINX_DOCKER_GEN_CONTAINER env var on the letsencrypt-companion container to the name of the docker-gen container." >&2
        echo -e "\t- Label the docker-gen container to use with 'com.github.jrcs.letsencrypt_nginx_proxy_companion.docker_gen.'" >&2
        exit 1
    fi
    check_writable_directory '/etc/nginx/certs'
    check_writable_directory '/etc/nginx/vhost.d'
    check_writable_directory '/usr/share/nginx/html'
    check_deprecated_env_var
    check_dh_group
fi

exec "$@"
