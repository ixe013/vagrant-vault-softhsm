#!/bin/bash

: ${CONFIG_BASE:=$HOME/.config}

#Default values
: ${NODES:=3}

: ${API_PORT:=8200}
: ${CLUSTER_PORT:=$(( $API_PORT+1 ))}
: ${CLUSTER_IDENTIFIER:=cluster_${API_PORT}}
: ${SOFTHSM2_CONF:=$CONFIG_BASE/softhsm2/$CLUSTER_IDENTIFIER/softhsm2.conf}

export SOFTHSM2_CONF

herefile() {
  expand | awk 'NR == 1 {match($0, /^ */); l = RLENGTH + 1} {print substr($0, l)}'
}


function clean {
    echo Deleting previous tokens and vault data...
    rm -Rf \
        $CONFIG_BASE/softhsm2/$CLUSTER_IDENTIFIER \
        $CONFIG_BASE/vault/$CLUSTER_IDENTIFIER \
        ;
}


function config {
    mkdir -vp \
        $CONFIG_BASE/softhsm2/$CLUSTER_IDENTIFIER/tokens/ \
        $CONFIG_BASE/vault/$CLUSTER_IDENTIFIER/1 \
        $CONFIG_BASE/vault/$CLUSTER_IDENTIFIER/2 \
        $CONFIG_BASE/vault/$CLUSTER_IDENTIFIER/3 \
        ;

    herefile << EOF > $CONFIG_BASE/softhsm2/$CLUSTER_IDENTIFIER/softhsm2.conf
        # SoftHSM v2 configuration file
        directories.tokendir = $CONFIG_BASE/softhsm2/$CLUSTER_IDENTIFIER/tokens/
        objectstore.backend = file
        # ERROR, WARNING, INFO, DEBUG
        log.level = DEBUG
EOF

    #Generate an HSM key per Vault instance
    softhsm2-util --init-token --free --label "vault-hsm-key" --pin 1234 --so-pin asdf
    VAULT_HSM_SLOT=$(softhsm2-util --show-slots | grep ^Slot | sed "q;d" | cut -d\  -f2)

    #Create Vault configuration files, each with its own HSM slot
    for (( N=1; N<=$NODES; N++ ))
    do
        herefile << EOF > $CONFIG_BASE/vault/$CLUSTER_IDENTIFIER/${N}/config.hcl
            listener "tcp" {
              address = "127.0.0.${N}:$API_PORT"
              tls_disable = "true"
            }

            storage "raft" {
              path = "$CONFIG_BASE/vault/$CLUSTER_IDENTIFIER/${N}"
              node_id = "data-vault-$API_PORT-${N}"
            }

            #I am testing on WSL which does not support mlock
            disable_mlock = true

            ui = true
            api_addr = "http://127.0.0.${N}:$API_PORT"
            cluster_addr = "https://127.0.0.${N}:$CLUSTER_PORT"

            pid_file = "$CONFIG_BASE/vault/$CLUSTER_IDENTIFIER/pid${N}"

            seal "pkcs11" {
              lib            = "/usr/lib/softhsm/libsofthsm2.so"
              slot           = "$VAULT_HSM_SLOT"
              pin            = "1234"
              key_label      = "vault-hsm-key"
              hmac_key_label = "vault-hsm-hmac-key"
              generate_key   = "true"
            }
EOF
    done

}


function install {
    echo Installing the required packages...
    sudo apt-get update 
    sudo apt-get install libltdl7 libsofthsm2 softhsm2 libltdl-dev opensc
}


function start_vault {
    for (( N=1; N<=$NODES; N++ ))
    do
        echo -n $N
        nohup vault server --config $CONFIG_BASE/vault/$CLUSTER_IDENTIFIER/${N}/config.hcl --log-level=trace >> vault${N}.log 2>&1 &
        until curl --fail --silent --max-time 5 http://127.0.0.${N}:${API_PORT}/v1/sys/health?standbycode=200\&sealedcode=200\&uninitcode=200\&drsecondarycode=200 --header "X-Vault-No-Request-Forwardilg: 1" -o /dev/null; do echo -n $N ; sleep 0.5; done
    done
 
    echo
    ps -ef | grep -v grep | grep "vault server"
}


function raft_join {
    echo "Building the Vault Raft cluster"
    
    # Start with node 2, node 1 is already Raft
    for (( N=2; N<=$NODES; N++ ))
    do
        VAULT_ADDR=http://127.0.0.${N}:$API_PORT vault operator raft join http://127.0.0.1:$API_PORT
    done
}


function stop_vault {
    echo "Stopping Vault(s)"
    
    for (( N=1; N<=$NODES; N++ ))
    do
        PID=$(cat $CONFIG_BASE/vault/$CLUSTER_IDENTIFIER/pid${N})
        echo "Waiting for vault pid $PID to end"
        kill $PID
        tail --pid=$PID -f /dev/null
    done
}

POSITIONAL=()
while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -h|--hsm)
        USE_HSM=1
        shift # past value
        ;;
        -n|--nodes)
        shift # past argument
        NODES=$2
        shift # past value
        echo Will use $NODES
        ;;
        *)    # unknown option
        POSITIONAL+=("$1") # save it in an array for later
        shift # past argument
        ;;
    esac
done

# Restore positional parameters
set -- "${POSITIONAL[@]}" 

# Call each task, in order
for task in $*
do
    case $task in
        install)
            install
            ;;
         
        clean)
            clean
            ;;
         
        config | configure)
            config
            ;;
         
        start)
            start_vault
            ;;
         
        join)
            raft_join
            ;;
         
        stop)
            stop_vault
            ;;
         
        *)
            echo $"Ignoring $task not in {install|clean|config[ure]|start}"
            exit 1
    esac
done
