# Proxmox Hookscript for FDB Management
As described in https://bugzilla.redhat.com/show_bug.cgi?id=1067802, when a linux bridge is attached to a physical function of a NIC that supports virtual functions using SR-IOV, MAC addresses for guests on the linux bridge are not automatically added to the forwarding database of the physical function's interface.

This hookscript can be attached to a VM using the following command:

`qm set <vmid> --hookscript local:snippets/bridgefix.sh`

or a container:

`pct set <vmid> --hookscript local:snippets/bridgefix.sh`

This will invoke a hookscript placed in the default snippet location of:
`/var/lib/vz/snippets/`

## Installation
`sudo wget -O /var/lib/vz/snippets/bridgefix.sh https://raw.githubusercontent.com/jdlayman/pve-hookscript-sriov/master/bridgefix.sh`
`sudo chmod 755 /var/lib/vz/snippets/bridgefix.sh`

## Implementation
1. The script searches the LXC/VM `<vmid>.conf` within `/etc/pve` to find the MAC address of all configured interfaces of the guest attached to a bridge. 
2. For each discovered bridge, the script looks for all interfaces connected to the bridge (linked within `/sys/class/net/<bridge>/brif/`.
3. If the interface is a bond, individual slave interfaces are determined by inspecting `/sys/class/net/<bond>/bonding`.
4. For each interface identified in steps #2 and #3, if the interface is a physical interface that also has virtual functions (as determined by the existence of links named  `/sys/class/net/<intf>/device/virtfn#`), the MAC address of the guest is added to the forwarding database for the interface using the following command: `bridge fdb add <mac-addr> dev <intf>`.

### References
- This script was originally provided by murky51 on the Proxmox forums: https://forum.proxmox.com/threads/communication-issue-between-sriov-vm-vf-and-ct-on-pf-bridge.68638/#post-448742
- Slides 21 and 22 of https://netdevconf.info/0.1/docs/netdev_tutorial_bridge_makita_150213.pdf also describe the problem and solution

