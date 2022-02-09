#!/bin/bash

# Don't forget to forward zone 196.10.10.in-addr.arpa. and gnali.lab. to controllers 10.10.192.12, 10.10.192.13, 10.10.192.14

set -xe
source ~/overcloudrc

# Create flavor
openstack flavor create --public --ram 512 --vcpus 1 --disk 1 cirros_flavor
openstack flavor create --public --ram 1024 --vcpus 1 --disk 15 rhel_flavor

# Create image
openstack image create --file ~/images/cirros-0.5.1-x86_64-disk.img  --container-format bare --disk-format qcow2 cirros
openstack image create --file ~/images/rhel-server-7.7-update-1-x86_64-kvm.qcow2  --container-format bare --disk-format qcow2 rhel7

# Create API network
openstack network create --provider-network-type vlan --provider-physical-network datacentre --provider-segment 492 --external --share api-network
openstack subnet create --subnet-range 10.10.192.0/20 --dhcp --gateway 10.10.192.1 --network api-network --allocation-pool start=10.10.192.200,end=10.10.192.220 api-subnet

# Create FIPS network
openstack network create --provider-network-type vlan --provider-physical-network datacentre --provider-segment 496 --external --share fips-network
openstack subnet create --subnet-range 10.10.196.0/24 --dhcp --gateway 10.10.196.1 --network fips-network --allocation-pool start=10.10.196.10,end=10.10.196.250 fips-subnet

# Create private network
openstack network create private-network
openstack subnet create --network private-network --subnet-range 172.16.66.0/24 private-subnet
openstack router create router1
openstack router add subnet router1 private-subnet
openstack router set --external-gateway fips-network router1

# Creat keypair
openstack keypair create --public-key ~/.ssh/id_rsa.pub stack

# Set default security group rules
openstack security group rule create --protocol icmp $(openstack security group list --project admin -c ID -f value)
openstack security group rule create --protocol tcp --dst-port 22 $(openstack security group list --project admin -c ID -f value)
openstack security group rule create --protocol tcp --dst-port 8080 $(openstack security group list --project admin -c ID -f value)

# Designate zone
openstack zone create --email admin@gnali.lab gnali.lab.

# Create instances with fixed ip on fips-network
openstack port create --network fips-network --fixed-ip subnet=fips-subnet,ip-address=10.10.196.201 rhel-server-port0
openstack server create --image rhel7 --flavor rhel_flavor --port rhel-server-port0 rhel-server --key-name stack --user-data ./cloud_init.cfg --wait
openstack recordset create gnali.lab. --type A --record 10.10.196.201 rhel-server
# configure provider network PTR
openstack zone create --email admin@gnali.lab 196.10.10.in-addr.arpa.
openstack recordset create 196.10.10.in-addr.arpa. --type PTR --record rhel-server.gnali.lab. 201

# Create instances with fixed ip on private-network
openstack port create --network private-network --fixed-ip subnet=private-subnet,ip-address=172.16.66.100 rhel-server2-port0
openstack server create --image rhel7 --flavor rhel_flavor --port rhel-server2-port0 rhel-server2 --key-name stack --user-data ./cloud_init2.cfg --wait
#openstack server create --image rhel7 --flavor rhel_flavor --network private-network rhel-server2 --key-name stack --user-data ./cloud_init2.cfg --wait

openstack port create --network private-network --fixed-ip subnet=private-subnet,ip-address=172.16.66.101 cirros-server-port0
openstack server create --image cirros --flavor cirros_flavor --port cirros-server-port0 cirros --key-name stack --user-data ./cirros_init.cfg --wait

# HTTP LB with FIPS
openstack loadbalancer create --name lb1 --vip-subnet-id private-subnet --vip-address 172.16.66.200
while [ "$(openstack loadbalancer show lb1 --column operating_status -f value)" != "ONLINE" ]; do echo "LB not Online";sleep 10; done
while [ "$(openstack loadbalancer show lb1 --column provisioning_status -f value)" != "ACTIVE" ]; do echo "LB not Active";sleep 10; done
openstack loadbalancer listener create --name listener1 --protocol HTTP --protocol-port 80 lb1
openstack loadbalancer pool create --name pool1 --lb-algorithm ROUND_ROBIN --listener listener1 --protocol HTTP
#openstack loadbalancer healthmonitor create --delay 5 --max-retries 4 --timeout 10 --type HTTP --url-path /healthcheck pool1
openstack loadbalancer member create --subnet-id private-subnet --address 172.16.66.100 --protocol-port 8080 pool1
openstack loadbalancer member create --subnet-id private-subnet --address 172.16.66.101 --protocol-port 8080 pool1
openstack floating ip create fips-network --floating-ip-address 10.10.196.202
load_balancer_vip_port_id=$(openstack loadbalancer show lb1 --column vip_port_id  -f value)
openstack floating ip set --port ${load_balancer_vip_port_id} 10.10.196.202
openstack recordset create gnali.lab. --type A --record 10.10.196.202 www
# Configure Floating IP Reverse
region=$(openstack region list -c Region -f value) 
floating_id=$(openstack floating ip show 10.10.196.202 --column id -f value)
openstack ptr record set ${region}:${floating_id} www.gnali.lab.

# Add HTTPS to previous LB
pushd ./cert
sed -i 's/IP.1 = .*/IP.1 = 10.10.196.202/' openssl.cnf
sed -i 's/DNS.1 = .*/DNS.1 = 10.10.196.202/' openssl.cnf
sed -i 's/DNS.2 = .*/DNS.2 = www.gnali.lab/' openssl.cnf

rm -f index.* serial* 1000.pem 
touch index.txt
echo 1000 > serial

# Create Key and CSR for httpd
openssl req -new -newkey rsa:4096 -nodes \
    -config openssl.cnf \
    -keyout lb1.key -out lb1.csr \
    -subj "/C=FR/ST=IDF/L=Paris/O=Red Hat/CN=www.gnali.lab"

# Sign CSR with undercloud CA
openssl ca -batch -config openssl.cnf -extensions v3_req -days 3650 \
    -in lb1.csr -out lb1.crt \
    -cert  ~/undercloud-cert/ca_cert/ca.crt.pem \
     -keyfile ~/undercloud-cert/ca_cert/ca.key.pem

openssl pkcs12 -export -inkey lb1.key -in lb1.crt -certfile ~/undercloud-cert/ca_cert/ca.crt.pem -passout pass: -out lb1.p12
popd

openstack secret store --name='tls_secret1' -t 'application/octet-stream' -e 'base64' --payload="$(base64 < cert/lb1.p12)"
openstack acl user add -u admin $(openstack secret list | awk '/ tls_secret1 / {print $2}')
openstack loadbalancer listener create --name listener2 --protocol TERMINATED_HTTPS --protocol-port 443 --default-tls-container=$(openstack secret list | awk '/ tls_secret1 / {print $2}') --default-pool pool1 lb1
