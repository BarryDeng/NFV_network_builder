#!/bin/bash

HOST_PER_NODE=1
ROUTER_NUM=6
SWITCH_NUM=0
FIREWALL_NUM=0
WEBSERVER_NUM=0

HOST_TEMPLATE_NAME="host"
IPERF_TEMPLATE_NAME="iperf"
ROUTER_TEMPLATE_NAME="router"
SWITCH_TEMPLATE_NAME="ovs"
WEBSERVER_TEMPLATE_NAME="webserver"
FIREWALL_TEMPLATE_NAME="suricata"

NODE_TYPE=(h r s fw ws)

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

set_host_interface() {
    local config="/var/lib/lxc/$1/rootfs/etc/network/interfaces"
    grep "address $2" $config > /dev/null || sed -i "s/iface eth0 inet dhcp/iface eth0 inet static/
		$ a address $2
		$ a netmask 255.255.255.0 
		$ a gateway ${2%.*}.2" \
		$config
} 

new_ospf_config() {
    local config="/var/lib/lxc/$1/rootfs/etc/quagga/ospfd.conf"
    grep '^router ospf' $config > /dev/null || `echo "router ospf" >> $config` 
    grep "^network $2/24 area 0" $config > /dev/null || `sed -i "/^router ospf/anetwork $2\/24 area 0" $config`
}

edit_config() {
    local name=${1%-*}
    local config="/var/lib/lxc/$name/config"
    echo "# Network configuration" >> $config
    echo "lxc.network.type = veth" >> $config
    echo "lxc.network.link = $2" >> $config
    echo "lxc.network.veth.pair = $1" >> $config
    echo "lxc.network.flags = up" >> $config
    [ -n "$3" ] && echo "lxc.network.ipv4 = $3/24" >> $config
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
    brctl addbr $brname > /dev/null || echo "$brname already exists!"
    brctl stp $brname on
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
    usage: $PROGNAME [options]

    Build a nfv network environment based on LXCs.
    OPTIONS:
        -v, --view             view the network nodes
        -c, --create           create the network
        -r, --run              run the network
        -s, --stop             stop the network
        -d, --destroy          destroy the network nodes

EOF
}

create() {
    echo "Now create nodes..."
    # create nodes
    for i in $(seq 1 $((HOST_PER_NODE * ROUTER_NUM - 2))); do
        [[ $i != 1 && $i != $((ROUTER_NUM / 2)) ]] && build_new_container h$i $HOST_TEMPLATE_NAME \
		|| build_new_container h$i $IPERF_TEMPLATE_NAME
        new_config h$i
    done

    for i in $(seq 1 $ROUTER_NUM); do
	build_new_container r$i $ROUTER_TEMPLATE_NAME
    	new_config r$i
    done

    # Create links

    # HOST_PER_NODE * ROUTER_NUM - 2(CORE_ROUTER_NUM) - 1
    for i in $(seq 0 $((HOST_PER_NODE * ROUTER_NUM - 3))); do
	for j in $(seq 0 $((HOST_PER_NODE - 1))); do 
	    echo "Create link between h`expr $i + 1`-eth0 and r`expr $i + 1`-eth$j"
            create_bridge h$((i + 1))-eth0 r$((i + 1))-eth$j 192.168.$((i + 1)).1 192.168.$((i + 1)).2
            # set_host_interface h$((i + 1)) 192.168.$((i + 1)).1
	    new_ospf_config r$((i + 1)) 192.168.$((i + 1)).0
	done
    done

    local subnet_num=$((HOST_PER_NODE * ROUTER_NUM - 1))
    for i in $(seq 0 $((ROUTER_NUM / 2 - 2))); do
	echo "Create link between r$((i + 1))-eth1 and r$((ROUTER_NUM - 1))-eth$i" 
	create_bridge r$((i + 1))-eth1 r$((ROUTER_NUM - 1))-eth$i 192.168.$subnet_num.1 192.168.$subnet_num.2
        new_ospf_config r$((i + 1)) 192.168.$subnet_num.0
	new_ospf_config r$((ROUTER_NUM - 1)) 192.168.$subnet_num.0 
        subnet_num=$((subnet_num + 1))
    done

    for i in $(seq $((ROUTER_NUM / 2 - 1)) $((ROUTER_NUM - 3))); do
	echo "Create link between r$((i + 1))-eth1 and r$ROUTER_NUM-eth$((i + 1 - ROUTER_NUM / 2))"
	create_bridge r$((i + 1))-eth1 r$ROUTER_NUM-eth$((i + 1 - ROUTER_NUM / 2)) 192.168.$subnet_num.1 192.168.$subnet_num.2
	new_ospf_config r$((i + 1)) 192.168.$subnet_num.0 
	new_ospf_config r$ROUTER_NUM 192.168.$subnet_num.0 
        subnet_num=$((subnet_num + 1))
    done

    echo "Create link between r$((ROUTER_NUM - 1))-eth$((ROUTER_NUM / 2)) and r$ROUTER_NUM-eth$((ROUTER_NUM / 2))" 
    create_bridge r$((ROUTER_NUM - 1))-eth$((ROUTER_NUM / 2)) r$ROUTER_NUM-eth$((ROUTER_NUM / 2)) 192.168.$subnet_num.1 192.168.$subnet_num.2
    new_ospf_config r$((ROUTER_NUM - 1)) 192.168.$subnet_num.0
    new_ospf_config r$ROUTER_NUM 192.168.$subnet_num.0

    echo "Successful!"
    return 0
}

view() {
    lxc-ls -f
    brctl show
}

run() {
    # create nodes
    for i in $(seq 1 $((HOST_PER_NODE * ROUTER_NUM - 2))); do
        lxc-start -n h$i
	lxc-attach -n h$i -- ip route add default via 192.168.$i.2
    done

    for i in $(seq 1 $ROUTER_NUM); do
        lxc-start -n r$i
    done
}

stop() {
    # stop nodes
    for i in $(seq 1 $((HOST_PER_NODE * ROUTER_NUM - 2))); do
        lxc-stop -n h$i
    done

    for i in $(seq 1 $ROUTER_NUM); do
        lxc-stop -n r$i
    done

    for i in $(brctl show | awk '{ print $1 }' | grep NFVbr); do
        ip link set $i down && echo "Set $i down!"
    done
}

destroy() {
    # destroy nodes
    for i in $(seq 1 $((HOST_PER_NODE * ROUTER_NUM - 2))); do
        lxc-destroy -n h$i
    done

    for i in $(seq 1 $ROUTER_NUM); do
        lxc-destroy -n r$i
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
