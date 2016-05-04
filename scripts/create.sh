#!/bin/sh

set -e  -E

: ${HOST:=sat-62.virt.gonoph.net}
NAME=$(cut -d . -f 1 <<< "$HOST")
: ${HG:=RHEL7-Server}
MAC=
: ${IP:=$(host $HOST | sed -n 's/.*has address //p')}
[ -z "$IP" ] && { echo "$HOST does not have an ip address!" ; exit 1 ; }
: ${ORG:=1}
: ${LOCATION:=2}

: ${RHEVM_USER:=admin@internal}
: ${RHEVM_PASS:=redhat123}
PW="$RHEVM_USER:$RHEVM_PASS"
: ${url:=https://rhevm/ovirt-engine/api}
ovirt() {
  add_url="$1"
  shift
  curl -s --basic -k -u ${PW} ${url}${add_url} "$@" | tee /tmp/l
}

info() {
  echo -e "\e[0;34m#\e[32m" "$@" "\e[0m"
}

warn() {
  echo -e "\e[0;33m""$@""\e[0m"
}

warn "HOST=$HOST"
warn "NAME=$NAME"
warn "IP=$IP"
warn "HG=$HG"
warn "ORG=$ORG"
warn "LOCATION=$LOCATION"
if [ "x$1" = "xclean" ] ; then
  info "Cleaning up run for $HOST"
  hammer --csv host list --search name=${HOST} | tail -n +2 | cut -d , -f 1,2 | tr ',' ' ' > /tmp/x
  cat /tmp/x | while read HID H ; do
    info "Deleting $H with --id=$HID"
    hammer host delete --id=$HID
  done
  [ -s /tmp/x ] || info "Didn't find any satellite hosts named $HOST"

  HID=$(ovirt /vms/?search=name=$NAME | grep vm.href.*id= | sed 's/^.*id="\(.*\)".*$/\1/' )
  for id in $HID ; do
    info "Deleting $HOST with id=$id"
    ovirt /vms/$HID/stop -H 'Content-type: application/xml' -d '<action><async>false</async></action>' | grep state
    ovirt /vms/$HID -X DELETE | grep state
  done
  [ -z "$HID" ] && info "Didn't find any RHEVM VMs named $NAME"
  exit 1
fi

info "Creating VM: $NAME"
cat<< EOF >/tmp/x
<vm><name>${NAME}</name><template><name>Blank</name></template><cluster><name>AMD-Cheap</name></cluster><display><type>VNC</type></display><os type="rhel_7x64"><boot dev="hd"/><boot dev="network"/></os><type>server</type></vm>
EOF
VMS_ID=$(ovirt /vms -H "Content-type: application/xml" -d @/tmp/x | grep vm.href | grep id= | sed 's/^.* id="\(.*\)".*$/\1/')
warn "VMS_ID=$VMS_ID"
test -n "$VMS_ID"

info "Creating disk: disk1 for vms=$VMS_ID"
cat<< EOF >/tmp/x
<disk><provisioned_size>10737418240</provisioned_size><name>disk1</name><interface>virtio_scsi</interface><format>cow</format><storage_domains><storage_domain><name>ZFS-data</name></storage_domain></storage_domains><bootable>true</bootable></disk>
EOF
DISK_ID=$(ovirt /vms/$VMS_ID/disks -d @/tmp/x -H "Content-type: application/xml" | grep disk.href | grep id= | sed 's/^.* id="\(.*\)".*$/\1/')
warn "Disk_ID=$DISK_ID"
test -n "$DISK_ID"

info "Creating NIC for vms=$VMS_ID"
VNIC_PROFILE_ID=$(ovirt /vnicprofiles | grep 'vnic_profile.*id=' | sed 's/^.*id="\(.*\)".*$/\1/')
cat<<EOF > /tmp/x
<nic><name>eth0</name><vnic_profile id="$VNIC_PROFILE_ID" /></nic>
EOF
MAC=$(ovirt /vms/$VMS_ID/nics -H "Content-type: application/xml" -d @/tmp/x | grep mac.address | tr -d ' ' | tr '<>"' ',' | cut -d , -f 3)
warn "Mac=$MAC"
test -n "$MAC"

set +e +E
info "Waiting for disk to come online..."
I=10
while [ $I -gt 0 ] ; do
	ovirt /vms/$VMS_ID/disks/$DISK_ID | grep state | grep -q ok && break
	I=$[ $I - 1 ]
	sleep 1
	date
done

if [ $I -eq 0 ] ; then
	info "VM disk status isn't up!"
	exit 1
fi

set -e

info "Creating host in foreman: $HOST, mac=$MAC, ip=$IP"
hammer host create --name=${HOST} \
  --hostgroup=$HG \
  --interface="primary=true, provision=true, mac=${MAC}, ip=$IP" \
  --organization-id=$ORG \
  --location-id=$LOCATION \
  --root-password=redhat123
# --ask-root-password=yes


info "Starting VM to boot from network"
cat <<EOF > /tmp/x
<action><vm><os><boot dev="network"/><boot dev="hd"/></os></vm></action>
EOF
cat <<EOF > /tmp/x
<action/>
EOF
ovirt /vms/$VMS_ID/start \
-H "Content-type: application/xml" -d @/tmp/x | grep state
