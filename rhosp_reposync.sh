#!/bin/bash 

RHOSP_version="11"

# Set the following if you're using a proxy to reach Red Hat Network
PROXY_HOST="172.17.0.2"
PROXY_PORT="3128"
PROXY_USER=""
PROXY_PASS=""

# RHSM credentials
RHSM_USER=""
RHSM_POOL=""

# Uncomment to configure subscription-manager proxy use
#subscription-manager config --server.proxy_hostname="${PROXY_HOST}" --server.proxy_port="${PROXY_PORT}"

# you can add the following option if proxy need authentification
# --server.proxy_user="${PROXY_USER}"
# --server.proxy_password="${PROXY_PASS}"

# Configure host to retrieve packages
subscription-manager register --username ${RHSM_USER} --force
subscription-manager attach --pool=${RHSM_POOL}
subscription-manager repos --disable="*"
subscription-manager repos --enable="rhel-7-server-rpms"

# Make sure mandatory packages are installed
yum -y -q install httpd yum-utils createrepo iproute2

# Start httpd and open firewall is needed
systemctl start httpd && systemctl enable httpd
type firewall-cmd &> /dev/null && {
  firewall-cmd --zone=public --permanent --add-service=http
  firewall-cmd --reload
}



SYNC_DATE="$(date +%Y%m%d)-${RHOSP_version}"

REPO_LIST="rhel-7-server-satellite-tools-6.2-rpms \
	rhel-7-server-rpms \
	rhel-7-server-extras-rpms \
	rhel-7-server-rh-common-rpms \
	rhel-ha-for-rhel-7-server-rpms \
	rhel-7-server-openstack-${RHOSP_version}-rpms \
	rhel-7-server-openstack-${RHOSP_version}-devtools-rpms \
	rhel-7-server-rhceph-2-osd-rpms \
	rhel-7-server-rhceph-2-mon-rpms"

REPO_FOLDER="/var/www/html/${SYNC_DATE}"
REPO_CONF="${REPO_FOLDER}/local.repo"
REPO_URL="http://$(ip route get 1 | awk '{print $NF;exit}')/${SYNC_DATE}"

mkdir -p $REPO_FOLDER
/bin/rm -f $REPO_CONF
for REPO in $REPO_LIST
do
  echo "Sync of ${REPO}"
  reposync -l -n -d --repoid=${REPO} --download_path=${REPO_FOLDER}
  mkdir -p $REPO_FOLDER/$REPO
  cd $REPO_FOLDER/$REPO
  createrepo .


  cat >>$REPO_CONF<< EOF
[$REPO]
name=$REPO
baseurl=$REPO_URL/$REPO/
enabled=1
gpgcheck=0
EOF

done

# Unregister from RHSM
subscription-manager unsubscribe --all
subscription-manager unregister
subscription-manager clean
