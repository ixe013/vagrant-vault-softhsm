#!/bin/bash

CONFIG_BASE=$HOME/.config

#Default values
NODES=3
#Set this environment variable so that softhsm2-util uses our configuration file
SOFTHSM_CONF=$CONFIG_BASE/softhsm2/softhsm2.conf


herefile() {
  expand | awk 'NR == 1 {match($0, /^ */); l = RLENGTH + 1} {print substr($0, l)}'
}


function clean {
    echo Deleting previous tokens and vault data...
    rm -Rf \
        $CONFIG_BASE/softhsm2/ \
        $CONFIG_BASE/vault/1 \
        $CONFIG_BASE/vault/2 \
        $CONFIG_BASE/vault/3 \
        ;
}


function config {
    mkdir -p \
        $CONFIG_BASE/softhsm2/tokens/ \
        $CONFIG_BASE/vault/1 \
        $CONFIG_BASE/vault/2 \
        $CONFIG_BASE/vault/3 \
        ;

    herefile << EOF > $CONFIG_BASE/softhsm2/softhsm2.conf
        # SoftHSM v2 configuration file
        directories.tokendir = $CONFIG_BASE/softhsm2/tokens/
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
        herefile << EOF > $CONFIG_BASE/vault/${N}/config.hcl
            listener "tcp" {
              address = "127.0.0.${N}:8200"
              tls_disable = "true"
            }

            storage "raft" {
              path = "$CONFIG_BASE/vault/${N}"
              node_id = "data-vault-${N}"
            }

            #I am testing on WSL which does not support mlock
            disable_mlock = true

            ui = true
            api_addr = "http://127.0.0.${N}:8200"
            cluster_addr = "https://127.0.0.${N}:8201"

            pid_file = "$CONFIG_BASE/vault/pid${N}"

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
        nohup vault server --config $CONFIG_BASE/vault/${N}/config.hcl --log-level=trace 2>&1 > vault${N}.log &
        sleep 1 ; #Seems to help with auto-unsel, as if SoftHSM2 can't handle concurrency
    done

    ps -ef | grep -v grep | grep "vault server"
}

function stop_vault {
    echo "Stopping Vault(s)"
    
    for (( N=1; N<=$NODES; N++ ))
    do
        echo " pid $(cat $CONFIG_BASE/vault/pid${N})"
        kill $(cat $CONFIG_BASE/vault/pid${N})
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
         
        stop)
            stop_vault
            ;;
         
        *)
            echo $"Ignoring $task not in {install|clean|config[ure]|start}"
            exit 1
    esac
done
