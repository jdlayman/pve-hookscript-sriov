#!/bin/bash

# Hook script for PVE guests (hookscript config option)
# You can set this via pct/qm with
# pct set <vmid> -hookscript <volume-id>
# qm set <vmid> -hookscript <volume-id>
# where <volume-id> has to be an executable file in the snippets folder
# of any storage with directories e.g.:
# for KVM: qm set 100 -hookscript local:snippets/pf-bridge-fdb.sh
# or
# for CT: pct set 100 -hookscript local:snippets/pf-bridge-fdb.sh

#
# Modified from ctr's hookscript to add bridged CT and VM MAC addresses to the upstream PF interface.
# https://forum.proxmox.com/threads/communication-issue-between-sriov-vm-vf-and-ct-on-pf-bridge.68638/#post-435959
# 

USAGE="Usage: $0 vmid phase"

if [ "$#" -ne "2" ]; then
  echo "$USAGE"
  exit 1
fi

echo "GUEST HOOK: $0 $*"

# First argument is the vmid

vmid=$1
if [[ $1 == ?(-)+([:digit:]) ]]; then
  echo "$USAGE"
  exit 1
fi

# Second argument is the phase

phase=$2
case "${phase}" in
  pre-start|post-start|pre-stop|post-stop) : ;;
  *)                                       echo "got unknown phase ${phase}"; exit 1 ;;
esac

function get_physical_interfaces {
    local interface=$1
    log "Get: ${interface}"
    local result=()
    # find interfaces that are bonded
    if [ -d "/sys/class/net/${interface}/bonding" ]; then
        #get bonded interfaces
        #local bondedints=$(cat /sys/class/net/${interface}/bonding/slaves 2>/dev/null)
        IFS=' ' read -a bondedints <<< "$(cat /sys/class/net/${interface}/bonding/slaves 2>/dev/null)"
        for bondedint in "${bondedints[@]}"; do
            local ints=("$(get_physical_interfaces "${bondedint}")")
            result+=("${ints[@]}")
        done
    else
        result+=("$interface") 
    fi
    echo "${result[@]}"
    return 1
}

function get_bridge_physical_interfaces_with_virtual_functions {
    local interface=$1
    local result=()
    # find interfaces that are bonded
    log "Search Interfaces: ${interface}"
    IFS=' ' read -a physicalints <<< "$(get_physical_interfaces "${interface}")"
    for physicalint in "${physicalints[@]}"; do
        log "Found: ${physicalint}"
        if [ -L "/sys/class/net/${physicalint}/device/physfn" ] || [ -L "/sys/class/net/${physicalint}/device/virtfn0" ]; then
            result+=("${physicalint}")
        fi
    done
    echo "${result[@]}"
}

function update_bridge { 
    local macaddr=$1
    local interface=$2
    local present
    present=$(bridge fdb show dev "${interface}" | grep -F -i "${macaddr}")
          if [[ -z $present && "${OPERATION}" = "add" ]] || [[ -n $present && "${OPERATION}" = "del" ]]; then
            #echo bridge fdb "${OPERATION} ${macaddr} dev ${interface}"
            bridge fdb "${OPERATION}" "${macaddr}" dev "${interface}"
          fi
}

function fixup_bridge_fdb {
  OPERATION=$1
  # Lookup Proxmox config for by vmid
  CONFFILE=$(find /etc/pve -type f -name "${vmid}.conf")
  if [ -f "${CONFFILE}" ]; then
    # get defined networks
    NETWORKS=$(egrep "^net" ${CONFFILE}| fgrep bridge= | awk '{print $2}')
    #echo $NETWORKS
    for i in ${NETWORKS}; do
      #echo $i
      declare macaddr=""
      declare bridge=""
      declare vlan=""
      IFS=\, read -a NETWORK <<<"$i"
      # get attributes for current network
      for item in "${NETWORK[@]}"; do
        IFS=\= read -a kv <<<"$item"
        case "${kv[0]}" in 
          tag)     vlan=${kv[1]};;
          bridge)  bridge=${kv[1]};;
          virtio)  macaddr=${kv[1]};;
          hwaddr)  macaddr=${kv[1]};;
          vmxnet3) macaddr=${kv[1]};;
        esac
      done
      # special processing needed if member of vlan
      if [ ! -z "${vlan}" ]; then
        vlancheck=${vlan}
      else
        vlancheck="checking"
      fi
      # lookup member interfaces of defined bridge interface
      bridgeinterfaces=$(ls -1 /sys/class/net/${bridge}/brif/ 2>/dev/null)
      # for every member interface, if it is an SR-IOV PF then ...
      #echo $bridgeinterfaces
      for memberint in ${bridgeinterfaces}; do
        local bondedints=("$(get_bridge_physical_interfaces_with_virtual_functions ${memberint})")
        for bondedint in "${bondedints[@]}"; do
           if [ "${bondedint}" != "" ]; then
                update_bridge "${macaddr}" "${bondedint}"
           fi
        done
      done
    done
  else
    echo "VM or CT does not exist, aborting"
  fi
}

function log {
  local result=$1
        #echo $result >> log.txt
}

case "${phase}" in
  pre-start)  echo "${vmid} is starting, doing bridge fdb setup." && fixup_bridge_fdb add ;;
  post-stop)  echo "${vmid} stopped. Doing bridge fdb cleanup." && fixup_bridge_fdb del ;;
esac

exit 0

