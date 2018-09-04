#!/usr/bin/env bash

dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

# Internal variables used in the Vagrantfile
export 'EARVWAN_SCRIPT'=true
# Sets the directory where the temporary setup scripts are created
export 'EARVWAN_TEMP'="${dir}"

# export 'K8S'="1"
export 'NWORKERS'=1

export 'VM_MEMORY'=${MEMORY:-3072}
# Number of CPUs
export 'VM_CPUS'=${CPUS:-2}

# VM_BASENAME tag is only set if K8S option is active
export 'VM_BASENAME'="k8s"

# Set VAGRANT_DEFAULT_PROVIDER to virtualbox
export 'VAGRANT_DEFAULT_PROVIDER'=${VAGRANT_DEFAULT_PROVIDER:-"virtualbox"}
# Sets the default cilium TUNNEL_MODE to "vxlan"



# Master's IPv4 address. Workers' IPv4 address will have their IP incremented by
# 1. The netmask used will be /24
export 'MASTER_IPV4'=${MASTER_IPV4:-"192.168.33.11"}
# NFS address is only set if NFS option is active. This will create a new
# network interface for each VM with starting on this IP. This IP will be
# available to reach from the host.
export 'MASTER_IPV4_NFS'=${MASTER_IPV4_NFS:-"192.168.34.11"}
# Enable IPv4 mode. It's enabled by default since it's required for several
# runtime tests.
export 'IPV4'=${IPV4:-1}

# Exposed IPv6 node CIDR, only set if IPV4 is disabled. Each node will be setup
# with a IPv6 network available from the host with $IPV6_PUBLIC_CIDR +
# 6to4($MASTER_IPV4). For IPv4 "192.168.33.11" we will have for example:
#   master  : FD00::B/16
#   worker 1: FD00::C/16
# The netmask used will be /16
# ~EARVWAN~ This is the InternalIP for each node in k8. Try:  kubectl get nodes -o json | grep -i -C 10 InternalIP
export 'IPV6_PUBLIC_CIDR'=${IPV4+"FD00::"}

# Internal IPv6 node CIDR, always set up by default. Each node will be setup
# with a IPv6 network available from the host with IPV6_INTERNAL_CIDR +
# 6to4($MASTER_IPV4). For IPv4 "192.168.33.11" we will have for example:
#   master  : FD01::B/16
#   worker 1: FD01::C/16
# The netmask used will be /16
export 'IPV6_INTERNAL_CIDR'=${IPV4+"FD01::"}

# Cilium IPv6 node CIDR. Each node will be setup with IPv6 network of
# $CILIUM_IPV6_NODE_CIDR + 6to4($MASTER_IPV4). For IPv4 "192.168.33.11" we will
# have for example:
#   master  : FD02::0:0:0/96
#   worker 1: FD02::1:0:0/96
# ~EARVWAN~ This is the PodCIDR. Try: kubectl get nodes -o json | grep -i -C 10 podCIDR 
export 'CILIUM_IPV6_NODE_CIDR'=${CILIUM_IPV6_NODE_CIDR:-"FD02::"}
# VM memory



# split_ipv4 splits an IPv4 address into a bash array and assigns it to ${1}.
# Exits if ${2} is an invalid IPv4 address.
function split_ipv4(){
    IFS='.' read -r -a ipv4_array <<< "${2}"
    eval "${1}=( ${ipv4_array[@]} )"
    if [[ "${#ipv4_array[@]}" -ne 4 ]]; then
        echo "Invalid IPv4 address: ${2}"
        exit 1
    fi
}

# get_cilium_node_addr sets the cilium node address in ${1} for the IPv4 address
# in ${2}.
function get_cilium_node_addr(){
    split_ipv4 ipv4_array "${2}"
    hexIPv4=$(printf "%02X%02X:%02X%02X" "${ipv4_array[0]}" "${ipv4_array[1]}" "${ipv4_array[2]}" "${ipv4_array[3]}")
    eval "${1}=${CILIUM_IPV6_NODE_CIDR}${hexIPv4}:0:0"
}



# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~`#
# 				Network Configs (written in node-1.sh, ...)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~`#

# write_netcfg_header creates the file in ${3} and writes the internal network
# configuration for the vm IP ${1}. Sets the master's hostname with IPv6 address
# in ${2}.
function write_netcfg_header(){
    vm_ipv6="${1}"
    master_ipv6="${2}"
    filename="${3}"
    cat <<EOF > "${filename}"
#!/usr/bin/env bash

if [ -n "${K8S}" ]; then
    export K8S="1"
fi

# Use of IPv6 'documentation block' to provide example
ip -6 a a ${vm_ipv6}/16 dev enp0s8

echo '${master_ipv6} ${VM_BASENAME}1' >> /etc/hosts
sysctl -w net.ipv6.conf.all.forwarding=1
EOF
}

# write_master_route writes the cilium IPv4 and IPv6 routes for master in ${6}.
# Uses the IPv4 suffix in ${1} for the IPv4 route and cilium IPv6 in ${2} via
# ${3} for the IPv6 route. Sets the worker's hostname based on the index defined
# in ${4} with the IPv6 defined in ${5}.
function write_master_route(){
    master_ipv4_suffix="${1}"
    master_cilium_ipv6="${2}"
    master_ipv6="${3}"
    node_index="${4}"
    worker_ipv6="${5}"
    filename="${6}"

    cat <<EOF >> "${filename}"
echo "${worker_ipv6} ${VM_BASENAME}${node_index}" >> /etc/hosts

EOF
}

# write_nodes_routes writes in file ${3} the routes for all nodes in the
# clusters except for node with index ${1}. All routes will be based on IPv4
# defined in ${2}.
function write_nodes_routes(){
    node_index="${1}"
    base_ipv4_addr="${2}"
    filename="${3}"
    cat <<EOF >> "${filename}"
# Node's routes
EOF
    split_ipv4 ipv4_array "${base_ipv4_addr}"
    local i
    local index=1
    for i in `seq $(( ipv4_array[3] + 1 )) $(( ipv4_array[3] + NWORKERS ))`; do
        index=$(( index + 1 ))
        hexIPv4=$(printf "%02X%02X:%02X%02X" "${ipv4_array[0]}" "${ipv4_array[1]}" "${ipv4_array[2]}" "${i}")
        if [ "${node_index}" -eq "${index}" ]; then
            continue
        fi
        worker_internal_ipv6=${IPV6_INTERNAL_CIDR}$(printf "%02X" "${i}")

        cat <<EOF >> "${filename}"
echo "${worker_internal_ipv6} ${VM_BASENAME}${index}" >> /etc/hosts
EOF
    done

    cat <<EOF >> "${filename}"

EOF
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~`#
#			Create Master & Node Config files (node-1.sh, ...) 
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~`#

function create_master(){
    split_ipv4 ipv4_array "${MASTER_IPV4}"
    get_cilium_node_addr master_cilium_ipv6 "${MASTER_IPV4}"
    output_file="${dir}/node-1.sh"
    write_netcfg_header "${MASTER_IPV6}" "${MASTER_IPV6}" "${output_file}"

    if [ -n "${NWORKERS}" ]; then
        write_nodes_routes 1 "${MASTER_IPV4}" "${output_file}"
    fi

    # write_cilium_cfg 1 "${ipv4_array[3]}" "${master_cilium_ipv6}" "${output_file}"
}

function create_workers(){
    split_ipv4 ipv4_array "${MASTER_IPV4}"
    master_prefix_ip="${ipv4_array[3]}"
    get_cilium_node_addr master_cilium_ipv6 "${MASTER_IPV4}"
    base_workers_ip=$(printf "%d.%d.%d." "${ipv4_array[0]}" "${ipv4_array[1]}" "${ipv4_array[2]}")
    if [ -n "${NWORKERS}" ]; then
        for i in `seq 2 $(( NWORKERS + 1 ))`; do
            output_file="${dir}/node-${i}.sh"
            worker_ip_suffix=$(( ipv4_array[3] + i - 1 ))
            worker_ipv6=${IPV6_INTERNAL_CIDR}$(printf '%02X' ${worker_ip_suffix})
            worker_host_ipv6=${IPV6_PUBLIC_CIDR}$(printf '%02X' ${worker_ip_suffix})
            ipv6_public_workers_addrs+=(${worker_host_ipv6})

            write_netcfg_header "${worker_ipv6}" "${MASTER_IPV6}" "${output_file}"

            write_master_route "${master_prefix_ip}" "${master_cilium_ipv6}" \
                "${MASTER_IPV6}" "${i}" "${worker_ipv6}" "${output_file}"
            write_nodes_routes "${i}" ${MASTER_IPV4} "${output_file}"

            worker_cilium_ipv4="${base_workers_ip}${worker_ip_suffix}"
            get_cilium_node_addr worker_cilium_ipv6 "${worker_cilium_ipv4}"
            # write_cilium_cfg "${i}" "${worker_ip_suffix}" "${worker_cilium_ipv6}" "${output_file}"
        done
    fi
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~`#
# 						Vagrant & Virtualbox Functions 
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~`#

# set_vagrant_env sets up Vagrantfile environment variables
function set_vagrant_env(){
    split_ipv4 ipv4_array "${MASTER_IPV4}"
    export 'IPV4_BASE_ADDR'="$(printf "%d.%d.%d." "${ipv4_array[0]}" "${ipv4_array[1]}" "${ipv4_array[2]}")"
    export 'FIRST_IP_SUFFIX'="${ipv4_array[3]}"
    export 'MASTER_IPV6_PUBLIC'="${IPV6_PUBLIC_CIDR}$(printf '%02X' ${ipv4_array[3]})"

    split_ipv4 ipv4_array_nfs "${MASTER_IPV4_NFS}"
    export 'IPV4_BASE_ADDR_NFS'="$(printf "%d.%d.%d." "${ipv4_array_nfs[0]}" "${ipv4_array_nfs[1]}" "${ipv4_array_nfs[2]}")"
    export 'FIRST_IP_SUFFIX_NFS'="${ipv4_array[3]}"
    if [[ -n "${NFS}" ]]; then
        echo "# NFS enabled. don't forget to enable this ports on your host"
        echo "# before starting the VMs in order to have nfs working"
        echo "# iptables -I INPUT -p udp -s ${IPV4_BASE_ADDR_NFS}0/24 --dport 111 -j ACCEPT"
        echo "# iptables -I INPUT -p udp -s ${IPV4_BASE_ADDR_NFS}0/24 --dport 2049 -j ACCEPT"
        echo "# iptables -I INPUT -p udp -s ${IPV4_BASE_ADDR_NFS}0/24 --dport 20048 -j ACCEPT"
    fi

    temp=$(printf " %s" "${ipv6_public_workers_addrs[@]}")
    export 'IPV6_PUBLIC_WORKERS_ADDRS'="${temp:1}"
    if [[ "${IPV4}" -ne "1" ]]; then
        export 'IPV6_EXT'=1
    fi
}


# vboxnet_create_new_interface creates a new host only network interface with
# VBoxManage utility. Returns the created interface name in ${1}.
function vboxnet_create_new_interface(){
    output=$(VBoxManage hostonlyif create)
    vboxnet_interface=$(echo "${output}" | grep -oE "'[a-zA-Z0-9]+'" | sed "s/'//g")
    if [ -z "${vboxnet_interface}" ]; then
        echo "Unable create VBox hostonly interface:"
        echo "${output}"
        return
    fi
    eval "${1}=${vboxnet_interface}"
}

# vboxnet_add_ipv6 adds the IPv6 in ${2} with the netmask length in ${3} in the
# hostonly network interface set in ${1}.
function vboxnet_add_ipv6(){
    vboxnetif="${1}"
    ipv6="${2}"
    ipv6_mask="${3}"
    VBoxManage hostonlyif ipconfig "${vboxnetif}" \
        --ipv6 "${ipv6}" --netmasklengthv6 "${ipv6_mask}"
}

# vboxnet_add_ipv4 adds the IPv4 in ${2} with the netmask in ${3} in the
# hostonly network interface set in ${1}.
function vboxnet_add_ipv4(){
    vboxnetif="${1}"
    ipv4="${2}"
    ipv4_mask="${3}"
    VBoxManage hostonlyif ipconfig "${vboxnetif}" \
        --ip "${ipv4}" --netmask "${ipv4_mask}"
}

# vboxnet_addr_finder checks if any vboxnet interface has the IPv6 public CIDR
function vboxnet_addr_finder(){
    if [ -z "${IPV6_EXT}" ] && [ -z "${NFS}" ]; then
        return
    fi

    all_vbox_interfaces=$(VBoxManage list hostonlyifs | grep -E "^Name|IPV6Address|IPV6NetworkMaskPrefixLength" | awk -F" " '{print $2}')
    # all_vbox_interfaces format example:
    # vboxnet0
    # fd00:0000:0000:0000:0000:0000:0000:0001
    # 64
    # vboxnet1
    # fd05:0000:0000:0000:0000:0000:0000:0001
    # 16
    if [[ -n "${RELOAD}" ]]; then
        all_ifaces=$(echo "${all_vbox_interfaces}" | awk 'NR % 3 == 1')
        if [[ -n "${all_ifaces}" ]]; then
            while read -r iface; do
                iface_addresses=$(ip addr show "$iface" | grep inet6 | sed 's/.*inet6 \([a-fA-F0-9:/]\+\).*/\1/g')
                # iface_addresses format example:
                # fd00::1/64
                # fe80::800:27ff:fe00:2/64
                if [[ -z "${iface_addresses}" ]]; then
                    # No inet6 addresses
                    continue
                fi
                while read -r ip; do
                    if [ ! -z $(echo "${ip}" | grep -i "${IPV6_PUBLIC_CIDR/::/:}") ]; then
                        found="1"
                        net_mask=$(echo "${ip}" | sed 's/.*\///')
                        vboxnetname="${iface}"
                        break
                    fi
                done <<< "${iface_addresses}"
                if [[ -n "${found}" ]]; then
                    break
                fi
            done <<< "${all_ifaces}"
        fi
    fi
    if [[ -z "${found}" ]]; then
        all_ipv6=$(echo "${all_vbox_interfaces}" | awk 'NR % 3 == 2')
        line_ip=0
        if [[ -n "${all_vbox_interfaces}" ]]; then
            while read -r ip; do
                line_ip=$(( $line_ip + 1 ))
                if [ ! -z $(echo "${ip}" | grep -i "${IPV6_PUBLIC_CIDR/::/:}") ]; then
                    found=${line_ip}
                    net_mask=$(echo "${all_vbox_interfaces}" | awk "NR == 3 * ${line_ip}")
                    vboxnetname=$(echo "${all_vbox_interfaces}" | awk "NR == 3 * ${line_ip} - 2")
                    break
                fi
            done <<< "${all_ipv6}"
        fi
    fi

    if [[ -z "${found}" ]]; then
        echo "WARN: VirtualBox interface with \"${IPV6_PUBLIC_CIDR}\" not found"
        if [ ${YES_TO_ALL} -eq "0" ]; then
            read -r -p "Create a new VBox hostonly network interface? [y/N] " response
        else
            response="Y"
        fi
        case "${response}" in
            [yY])
                echo "Creating VBox hostonly network..."
            ;;
            *)
                exit
            ;;
        esac
        vboxnet_create_new_interface vboxnetname
        if [ -z "${vboxnet_interface}" ]; then
            exit 1
        fi
    elif [[ "${net_mask}" -ne 64 ]]; then
        echo "WARN: VirtualBox interface with \"${IPV6_PUBLIC_CIDR}\" found in ${vboxnetname}"
        echo "but set wrong network mask (${net_mask} instead of 64)"
        if [ ${YES_TO_ALL} -eq "0" ]; then
            read -r -p "Change network mask of '${vboxnetname}' to 64? [y/N] " response
        else
            response="Y"
        fi
        case "${response}" in
            [yY])
                echo "Changing network mask to 64..."
            ;;
            *)
                exit
            ;;
        esac
    fi
    split_ipv4 ipv4_array_nfs "${MASTER_IPV4_NFS}"
    IPV4_BASE_ADDR_NFS="$(printf "%d.%d.%d.1" "${ipv4_array_nfs[0]}" "${ipv4_array_nfs[1]}" "${ipv4_array_nfs[2]}")"
    vboxnet_add_ipv6 "${vboxnetname}" "${IPV6_PUBLIC_CIDR}1" 64
    vboxnet_add_ipv4 "${vboxnetname}" "${IPV4_BASE_ADDR_NFS}" "255.255.255.0"
}

# Sets the RELOAD env variable with 1 if there is any VM printed by
# vagrant status.
function set_reload_if_vm_exists(){
    if [ -z "${RELOAD}" ]; then
        if [[ $(vagrant status 2>/dev/null | wc -l) -gt 1 && \
                ! $(vagrant status 2>/dev/null | grep "not created") ]]; then
            RELOAD=1
        fi
    fi
}


if [[ "${VAGRANT_DEFAULT_PROVIDER}" -eq "virtualbox" ]]; then
     vboxnet_addr_finder
fi

ipv6_public_workers_addrs=()

split_ipv4 ipv4_array "${MASTER_IPV4}"
MASTER_IPV6="${IPV6_INTERNAL_CIDR}$(printf '%02X' ${ipv4_array[3]})"

set_reload_if_vm_exists

create_master
create_workers
set_vagrant_env
# create_k8s_config							// TODO

# cd "${dir}/../.."

if [ -n "${RELOAD}" ]; then
    vagrant reload
elif [ -n "${NO_PROVISION}" ]; then
    vagrant up --no-provision
elif [ -n "${PROVISION}" ]; then
    vagrant provision
else
    vagrant up
    if [ -n "${K8S}" ]; then
    	echo "copying k8 config file to vagrant.kubeconfig"
    	# TODO
		# vagrant ssh k8s1 -- cat /home/vagrant/.kube/config | sed 's;server:.*:6443;server: https://k8s1:7443;g' > vagrant.kubeconfig		
	fi
	echo "Add '127.0.0.1 k8s1' to your /etc/hosts to use vagrant.kubeconfig file for kubectl"
fi

