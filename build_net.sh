#!/bin/bash

HOST_PER_NODE=2
SWITCH_NUM=3
FIREWALL_NUM=3
WEBSERVER_NUM=1

HOST_TEMPLATE_NAME="host"
SWITCH_TEMPLATE_NAME="ovs"
WEBSERVER_TEMPLATE_NAME="webserver"
FIREWALL_TEMPLATE_NAME="suricata"

NODE_TYPE=(h s fw ws)

build_new_container() {
    if [ -d "/var/lib/lxc/$1" ]; then
        echo "Container $1 already exists!"
        return
    fi
    lxc-copy -n $2 -N $1 && echo "Container $1 created!"
}

gen_mac_address() {
    local type
    local a
    local b
    local test
    local part1=$(echo ${1#*-} | egrep -o '([[:lower:]]+)' | head -n 1)
    if [[ $part1 == "eth" ]]; then part1=0; else part1=1; fi
    local part2=$(echo ${1%-*} | egrep -o '([[:lower:]]+)' | head -n 1)
    a=$(echo $1 | egrep -o '([[:digit:]]+)' | head -n 1)
    b=$(echo $1 | egrep -o '([[:digit:]]+)' | tail -n 1)

    for ((j=0; j < ${#NODE_TYPE[@]}; j++)); do
        if [[ $part2 == ${NODE_TYPE[j]} ]]; then
            type=$j
            break
        fi
    done
    printf "00:00:%02d:%02d:%02d:%02d" $part1 $type $a $((b+1))
}

new_config() {
    local config="/var/lib/lxc/$1/config"
    echo "Write config to $config"
    cat > $config <<EOF
# Template used to create this container: /usr/share/lxc/templates/lxc-ubuntu
# Parameters passed to the template:
# Template script checksum (SHA-1): 4d7c613c3c0a0efef4b23917f44888df507e662b
# For additional config options, please look at lxc.container.conf(5)

# Uncomment the following line to support nesting containers:
#lxc.include = /usr/share/lxc/config/nesting.conf
# (Be aware this has security implications)


# Common configuration
lxc.include = /usr/share/lxc/config/ubuntu.common.conf

# Container specific configuration
lxc.rootfs = /var/lib/lxc/$1/rootfs
lxc.rootfs.backend = dir
lxc.utsname = $1
lxc.arch = amd64
EOF
}

edit_config() {
    local name=${1%-*}
    local config="/var/lib/lxc/$name/config"
    echo "# Network configuration" >> $config
    echo "lxc.network.type = veth" >> $config
    echo "lxc.network.link = $2" >> $config
    echo "lxc.network.veth.pair = $1" >> $config
    echo "lxc.network.flags = up" >> $config
    [ -n "$3" ] && echo "lxc.network.ipv4 = $3" >> $config
    echo "lxc.network.hwaddr = "$(gen_mac_address $1) >> $config
}

#create_veth_pair() {
#    echo "Add veth pair $1 -> $2"
#    ip link add $1 type veth peer name $2
#    edit_config $1
#    edit_config $2
#    ip link set $1 up
#    ip link set $2 up
#}
br_num=0


create_bridge() {
    local brname=NFVbr$br_num
    brctl show $brname || echo "$brname already exists!"
    brctl addbr $brname
    brctl stp $brname off
    edit_config $1 $brname $3
    edit_config $2 $brname $4
    ip link set $brname up
    br_num=$((br_num+1))
}

start_container() {
    lxc-start -n $1
}

help() {
    cat <<-EOF
    usage: $PROGNAME options

    This is an example.
    OPTIONS:
        -v, --view             view the network nodes
        -c, --create           create the network
        -r, --run              run the network
        -s, --stop             stop the network
        -d, --destroy          destroy the network nodes

    Examples:
        Run all tests:
        $PROGNAME --test all
EOF
}

create() {
    echo "Now create nodes..."
    # create nodes
    for i in $(seq 0 $((HOST_PER_NODE * SWITCH_NUM - 1))); do
        build_new_container h$i $HOST_TEMPLATE_NAME
        new_config h$i
    done

    for i in $(seq 0 $((FIREWALL_NUM - 1))); do
        build_new_container fw$i $FIREWALL_TEMPLATE_NAME
        new_config fw$i
    done

    for i in $(seq 0 $((SWITCH_NUM - 1))); do
        build_new_container s$i $SWITCH_TEMPLATE_NAME
        new_config s$i
    done

    for i in $(seq 0 $((WEBSERVER_NUM - 1))); do
        build_new_container ws$i $WEBSERVER_TEMPLATE_NAME
        new_config ws$i
    done

    new_config router

 
    # Create links
    brctl addbr SDNbr
    for i in $(seq 0 $((SWITCH_NUM - 1))); do
        edit_config s$i-sdn0 SDNbr 10.1.1.$((i+1))
    done
    ip link set SDNbr up

    for i in $(seq 0 $((HOST_PER_NODE * SWITCH_NUM - 1))); do
        create_bridge h$i-eth0 s$((i / HOST_PER_NODE))-eth$((i % HOST_PER_NODE)) 10.0.0.$((i+1))
    done

    for i in $(seq 0 $((SWITCH_NUM - 2))); do
        create_bridge s$i-eth$HOST_PER_NODE s$((i + 1))-eth$((HOST_PER_NODE + 1))
    done
    create_bridge s$((SWITCH_NUM - 1))-eth$HOST_PER_NODE s0-eth$((HOST_PER_NODE + 1))

    for i in $(seq 0 $((FIREWALL_NUM - 1))); do
        create_bridge s$((SWITCH_NUM - 1))-eth$((HOST_PER_NODE + 2 + i)) fw$i-eth0 "" 10.0.0.$((101+i))
        create_bridge fw$i-eth1 router-eth$i 10.0.0.$((151+i)) 10.0.0.$((201+i))
    done

    for i in $(seq 0 $((WEBSERVER_NUM - 1))); do
        create_bridge router-eth$((FIREWALL_NUM + i)) ws$i-eth0 192.168.1.$((i+1)) 192.168.1.$((101+i))
    done

    echo "Successful!"
    return 0
}

view() {
    echo "TODO"
}

run() {
    # create nodes
    for i in $(seq 0 $((HOST_PER_NODE * SWITCH_NUM - 1))); do
        lxc-start -n h$i
    done

    for i in $(seq 0 $((FIREWALL_NUM - 1))); do
        lxc-start -n fw$i
    done

    for i in $(seq 0 $((SWITCH_NUM - 1))); do
        lxc-start -n s$i
    done

    for i in $(seq 0 $((WEBSERVER_NUM - 1))); do
        lxc-start -n ws$i
    done

    lxc-start -n router
}

stop() {
    # create nodes
    for i in $(seq 0 $((HOST_PER_NODE * SWITCH_NUM - 1))); do
        lxc-stop -n h$i
    done

    for i in $(seq 0 $((FIREWALL_NUM - 1))); do
        lxc-stop -n fw$i
    done

    for i in $(seq 0 $((SWITCH_NUM - 1))); do
        lxc-stop -n s$i
    done

    for i in $(seq 0 $((WEBSERVER_NUM - 1))); do
        lxc-stop -n ws$i
    done

    lxc-stop -n router

    for i in $(brctl show | awk '{ print $1 }' | grep NFVbr); do
        ip link set $i down || echo "Set $i down!"
    done
}

destroy() {
    # create nodes
    for i in $(seq 0 $((HOST_PER_NODE * SWITCH_NUM - 1))); do
        lxc-destroy -n h$i
    done

    for i in $(seq 0 $((FIREWALL_NUM - 1))); do
        lxc-destroy -n fw$i
    done

    for i in $(seq 0 $((SWITCH_NUM - 1))); do
        lxc-destroy -n s$i
    done

    for i in $(seq 0 $((WEBSERVER_NUM - 1))); do
        lxc-destroy -n ws$i
    done

    for i in $(brctl show | awk '{print $1}' | grep NFVbr); do
        brctl delbr $i
    done
}

cmdline() {
    [ $# -eq 0 ] && help
    local arg
    for arg in $@; do
        local delim=""
        case "$arg" in
            --create)
                args="${args}-c ";;
            --run)
                args="${args}-r ";;
            --view)
                args="${args}-v ";;
            --stop)
                args="${args}-s ";;
            --destroy)
                args="${args}-d ";;
            --help)
                args="${args}-h ";;
            *)
                [[ "${arg:0:1}" == "-" ]] || delim="\""; args="${args}${delim}${arg}${delim} ";;
       esac
    done
    eval set -- $args
    while getopts "crvsdh" OPTION; do
        case $OPTION in
            c)
                create
                ;;
            r)
                run
                ;;
            v)
                view
                ;;
            s)
                stop
                ;;
            d)
                destroy
                ;;
            h)
                help
                ;;
            *)
                echo "$PROGNAME -h/--help for help";
                exit 0
                ;;
        esac
    done


    # [[ ! -f $CONFIG_FILE ]] && echo "You must provide --config file" && exit 0

    return 0
}

main() {
    cmdline $@
}

main $@
