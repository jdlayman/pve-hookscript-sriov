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


function fixup_bridge_fdb {
  OPERATION=$1
  # Lookup Proxmox config for by vmid
  CONFFILE=$(find /etc/pve -type f -name ${vmid}.conf)
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
          vmxnet3)  macaddr=${kv[1]};;
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
	if [ -d "/sys/class/net/${memberint}/bonding" ]; then
          # find interfaces that are bonded
	  IFS=' ' read -a bondedints <<< $(cat /sys/class/net/${memberint}/bonding/slaves 2>/dev/null)
          for bondedint in ${bondedints[@]}; do
            #echo $bondedint
            if [ -L "/sys/class/net/${bondedint}/device/virtfn0" ]; then
              # echo $memberint
              subint="${bondedint}"
              # check if entry in fdb and only execute when needed
              present=$(bridge fdb show dev ${subint} | fgrep -i ${macaddr})
              if [[ -z $present && $OPERATION == "add" ]] || [[ -n $present && $OPERATION == "del" ]]; then
                echo bridge fdb ${OPERATION} ${macaddr} dev ${subint}
                bridge fdb ${OPERATION} ${macaddr} dev ${subint}
              fi
            fi
          done
        fi
        # only proceed if memberinterface is PF with VF
        if [ -L "/sys/class/net/${memberint}/device/virtfn0" ]; then
          # echo $memberint
          subint="${memberint}"
          ## check if a vf is on the vlan
          #vf=$(ip link show dev ${memberint} 2>/dev/null |awk -v vlan="${vlancheck}" '{ if( $6 ~ vlan) print $2}')
          #if [ ! -z "${vf}" ]; then
          #  if [ ! -z "${vlan}" ]; then
          #    subint="${memberint}.${vlan}"
          #  else
          #    subint="${memberint}"
          #  fi
          #fi
          # check if entry in fdb and only execute when needed
          present=$(bridge fdb show dev ${subint} | fgrep -i ${macaddr})
          if [[ -z $present && $OPERATION == "add" ]] || [[ -n $present && $OPERATION == "del" ]]; then
            echo bridge fdb ${OPERATION} ${macaddr} dev ${subint}
            bridge fdb ${OPERATION} ${macaddr} dev ${subint}
          fi
        fi
      done
    done
  else
    echo "VM or CT does not exist, aborting"
  fi
}

case "${phase}" in
  pre-start)  echo "${vmid} is starting, doing bridge fdb setup." && fixup_bridge_fdb add ;;
  post-stop)  echo "${vmid} stopped. Doing bridge fdb cleanup." && fixup_bridge_fdb del ;;
esac

exit 0

