#!/bin/bash -e

##########################################################################
#                                                                        #
#                               Miscellaneous                            #
#                                                                        #
##########################################################################

### Ensure $TERM is defined.
if [ "$TERM" = "dumb" ]; then export TERM="xterm-256color"; fi

### Fancy colors
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
NORMAL=$(tput sgr0)

##########################################################################
#                                                                        #
#                          Common Functions                              #
#                                                                        #
##########################################################################

#
#  Print info message to stderr
#
function echoinfo() {
  printf "\n${GREEN}INFO:${NORMAL} %s\n" "$*" >&2;
}

#
#  Print error message to stderr
#
function echoerr() {
  printf "\n${RED}ERROR:${NORMAL} %s\n" "$*" >&2;
}

#
#  Print exit message & exit 1
#
function exit_on_err()
{
  echoerr "Failed !!!! - Please check the output, fix the error and restart the script"
  exit 1
}


##########################################################################
#                                                                        #
#               Check dependencies + some sanity checks                  #
#                                                                        #
##########################################################################
# Are we on the undercloud/director
DIRECTOR_NODE=false
if [ -e /home/stack/undercloud.conf ]; then
  echoinfo "Script executed on Director node"
  DIRECTOR_NODE=true
fi

function check_requirements()
{
  # List of command dependencies
  local bin_dep="qemu-img virt-resize virt-filesystems virt-customize virt-cat"

  $DIRECTOR_NODE || {
    echoinfo "Enter director FQDN or IP : "
    read UNDERCLOUD
    echoinfo "Verifying $UNDERCLOUD is reachable..."
    [ "x$UNDERCLOUD" = "x" ] && {
                echoerr "undercloud address is empty"
                return 1
        }
    ping -c 3 $UNDERCLOUD || { echoerr "Failed to ping $UNDERCLOUD!"; return 1; }

    bin_dep="$bin_dep rsync"
  }

  echoinfo "---===== Checking dependencies =====---"

  for cmd in $bin_dep; do
    echoinfo "Checking for $cmd..."
    $cmd --version  >/dev/null 2>&1 || { echoerr "$cmd cannot be found... Aborting"; return 1; }
  done

   echoinfo "---===== Performing sanity checks =====---"
}


##########################################################################
#                                                                        #
#                             Main function                              #
#                                                                        #
##########################################################################

QCOW=overcloud-hardened-uefi-full.qcow2
TMP_DIR=${HOME}/overcloud-full-temp
IMAGE=${TMP_DIR}/${QCOW}

check_requirements || exit_on_err

mkdir -p ${TMP_DIR}

if $DIRECTOR_NODE; then
  IMG_SIZE=$(qemu-img info ~stack/images/${QCOW} | awk '/virtual size:/ {print $3}')
  qemu-img create -f qcow2 ${IMAGE} ${IMG_SIZE}G
  virt-resize --expand /dev/sda4 --lv-expand /dev/vg/lv_var ~stack/images/${QCOW} ${IMAGE}
else
  rsync -e ssh -a stack@${UNDERCLOUD}:images/${QCOW} ${IMAGE}.orig --progress

  IMG_SIZE=$(qemu-img info ${IMAGE}.orig | awk '/virtual size:/ {print $3}')
  qemu-img create -f qcow2 ${IMAGE} ${IMG_SIZE}G
  virt-resize --expand /dev/sda4 --lv-expand /dev/vg/lv_var ${IMAGE}.orig ${IMAGE}
fi

cat << EOF > ${TMP_DIR}/katello.facts
{"network.fqdn":"overcloud-full.$(hostname -d)"}
EOF

echoinfo "\
Go to https://satellite.$(hostname -d)/hosts/register

In General Tab:
  - Select Location
  - Select Capsule
  - Tick Insecure
  - Select same Activation Key used for update/upgrade or fresh install of OSP

In Advanced Tab:
  - Setup REX : NO
  - Setup Insight : NO
  - Tick Update Packages

Click on Generate, on copy/paste curl command bellow :
"
read varcurl


echoinfo "Updating ${IMAGE} with the same content view as OSP nodes"
virt-customize -a ${IMAGE} \
        --upload ${TMP_DIR}/katello.facts:/etc/rhsm/facts/katello.facts \
        --run-command "${varcurl}" \
        --run-command "subscription-manager remove --all" \
        --run-command "subscription-manager unregister" \
        --delete /etc/rhsm/facts/katello.facts --delete /tmp/builder.log --delete /var/lib/rhsm/facts/facts.json \
        --selinux-relabel

virt-cat -a ${IMAGE} /var/log/dnf.log
echoinfo "\
CHECK IF UPDATE IS OK

Review the output of /var/log/dnf.log within the image to check if update was successfull
"

while true; do

  read -p "Is ${QCOW} update OK ? (yes/no) : " yn

  case $yn in
    yes) echoinfo "${QCOW} update OK";
	 break;;
    no) echoerr "${QCOW} update failed";
	exit_on_err;;
    *) echo "invalid response";;
  esac
done

echoinfo "Copying back ${QCOW} to ~/stack/images/ on director"
if $DIRECTOR_NODE; then
  cp ${IMAGE} ~stack/images/${QCOW}
else
  rsync -e ssh -a ${IMAGE} stack@${UNDERCLOUD}:images/${QCOW} --progress
fi

echoinfo "Cleaning tmp files"
rm -rf ${TMP_DIR}
