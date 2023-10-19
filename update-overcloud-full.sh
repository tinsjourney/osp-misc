#!/bin/bash

UNDERCLOUD=$1
QCOW=overcloud-full.qcow2
TMP_DIR=${HOME}/overcloud-full-temp
IMAGE=${TMP_DIR}/${QCOW}

mkdir ${TMP_DIR}
rsync -e ssh -a stack@${UNDERCLOUD}:images/${QCOW} ${TMP_DIR}/ --progress
cat << EOF > ${TMP_DIR}/katello.facts
{"network.fqdn":"overcloud-full.$(hostname -d)"}
EOF

virt-customize -a ${IMAGE} --upload ${TMP_DIR}/katello.facts:/etc/rhsm/facts/katello.facts

## General Tab:
# Select Location
# Select Capsule
# Tick Insecure
# Select AK
## Advanced Tab:
# Setup REX => No
# Setup Insight => No
# Tick update packages
## Click Generate
echo "Paste curl command from https://satellite.$(hostname -d)/hosts/register"

read varcurl

virt-customize -a ${IMAGE} --run-command "${varcurl}"
virt-customize -a ${IMAGE} --run-command "subscription-manager remove --all"
virt-customize -a ${IMAGE} --run-command "subscription-manager unregister"
virt-customize -a ${IMAGE} --delete /etc/rhsm/facts/katello.facts --delete /tmp/builder.log --delete /var/lib/rhsm/facts/facts.json
virt-customize -a ${IMAGE} --selinux-relabel

rsync -e ssh -a ${IMAGE} stack@${UNDERCLOUD}:images/${QCOW} --progress

rm -rf ${TMP_DIR}
