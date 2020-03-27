# Bunch of heat stack to test OSP deployment


## Create provider network and flavor

* 00-public_network.yaml
 * Create floating IPs network and subnet
 * Create 2 vCPUs and 2G memory flavor

```
$ source ~/overcloudrc
$ openstack stack create -t 00-public_network.yaml provider-stack
```

If we want to override default parameters :

```
$ openstack stack create -t 00-public_network.yaml stack-00 \
	--parameter public_net_cidr=192.168.122.0/24 \
	--parameter public_net_gateway=192.168.122.1 \
	--parameter public_net_pool_start=192.168.122.170 \
	--parameter public_net_pool_end=192.168.122.180
```

## Upload Centos8 image to glance

```
$ source ~/overcloudrc
$ curl -OL https://cloud.centos.org/centos/8/x86_64/images/CentOS-8-GenericCloud-8.1.1912-20200113.3.x86_64.qcow2
$ qemu-img convert -f qcow2 -O raw CentOS-8-GenericCloud-8.1.1911-20200113.3.x86_64.qcow2 centos8.raw
$ openstack image create --disk-format raw --container-format bare --public centos8 --file centos8.raw
```

## Create project and add user to it

* 01-create_project.yaml
 * Create project
 * Create user
 * Create tenant network and subnet
 * Create router, attach tenant network and set provider network as default gateway

```
$ source ~/overcloudrc
$ openstack stack create -t 01-create_project.yaml stack-redhat \
	--parameter public_dns=8.8.8.8 \
	--parameter public_network=public
```

## Configure user RC file

```
$ sed -e 's/_NAME=admin/_NAME=Red_Hat_validation_project/' -e 's/RNAME=admin/RNAME=redhat_user/' -e 's/OS_PASSWORD=.*/OS_PASSWORD=redhat42/' ~/overcloudrc > ~/redhat.rc
```

## Create instances

* 02-create_vms.yaml
 * Create security group
 * Create key pair
 * Create instance vm1, attach a volume and add a floating ip
 * Create instance vm2, boot on volume and add a floating ip
 * Post-install instance to start http on port 8080
 
```
$ source ~/redhat.rc
$ openstack stack create -t 02-create_vms.yaml server-stack  \
	--parameter public_network=public \
	--parameter flavor=default --wait
```

Wait for instances post install to finish

```
$ sleep 80
```

Get instances floating ips

```
$ vm1_ip=$(openstack stack output show server-stack vm1_ip -c output_value -f value)
$ vm2_ip=$(openstack stack output show server-stack vm2_ip -c output_value -f value)
```

Check if web server answer on both instance

```
$ curl http://${vm1_ip}:8080
It Works for member: vm1
NAME   MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
vda    253:0    0  20G  0 disk
└─vda1 253:1    0  20G  0 part /
vdb    253:16   0  10G  0 disk
$ curl http://${vm2_ip}:8080
It Works for member: vm2
NAME   MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
vda    253:0    0  20G  0 disk
└─vda1 253:1    0  20G  0 part /
```

## Create load-balancers

* 03-create_lbs.yaml
 * Create load balance
 * Create listener on port 80
 * Assign round robin pool to listener
 * Define a healthcheck rule
 * Add pool member
 * Attach floating ip

Get instances private ips

```
$ vm1_tenant_ip=$(openstack server show vm1 -c addresses -f value |awk -F, 'gsub("private=","") {print $1}')
$ vm2_tenant_ip=$(openstack server show vm2 -c addresses -f value |awk -F, 'gsub("private=","") {print $1}')
```

Create load balancer

```
$ openstack stack create -t 03-create_lbs.yaml lb-stack  \
	--parameter public_network=external_fips \
	--parameter server1_tenant_ip=${vm1_tenant_ip} \
	--parameter server2_tenant_ip=${vm2_tenant_ip} \
	--wait
```

Get load balancer floating ip

```
$ lb_ip=$(openstack stack output show lb-stack lb_ip -c output_value -f value)
```

Test if both instance answer

```
$ curl http://${lb_ip}
It Works for member: vm1
NAME   MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
vda    253:0    0  20G  0 disk
└─vda1 253:1    0  20G  0 part /
vdb    253:16   0  10G  0 disk
$ curl http://${lb_ip}
It Works for member: vm1
NAME   MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
vda    253:0    0  20G  0 disk
└─vda1 253:1    0  20G  0 part /
vdb    253:16   0  10G  0 disk
```

Only instance vm1 answer, we need to check why ?

```
$ openstack loadbalancer show lb1 -c operating_status
+------------------+----------+
| Field            | Value    |
+------------------+----------+
| operating_status | DEGRADED |
+------------------+----------+
$ openstack loadbalancer pool show pool1 -c lb_algorithm -c protocol -c operating_status -c loadbalancers
+------------------+-------------+
| Field            | Value       |
+------------------+-------------+
| lb_algorithm     | ROUND_ROBIN |
| operating_status | DEGRADED    |
| protocol         | HTTP        |
+------------------+-------------+
$ openstack loadbalancer member list pool1
+--------------------------------------+------+----------------------------------+---------------------+-------------+---------------+------------------+--------+
| id                                   | name | project_id                       | provisioning_status | address     | protocol_port | operating_status | weight |
+--------------------------------------+------+----------------------------------+---------------------+-------------+---------------+------------------+--------+
| c0cdedf5-65a2-44b9-bd93-61501f6549b6 |      | 1810fe7db5e64e14a9edc01d093ef318 | ACTIVE              | 172.20.0.13 |          8080 | ONLINE           |      1 |
| b4f9a10d-ce8a-411d-98d8-f52934b2a344 |      | 1810fe7db5e64e14a9edc01d093ef318 | ACTIVE              | 172.20.0.17 |          8080 | ERROR            |      1 |
+--------------------------------------+------+----------------------------------+---------------------+-------------+---------------+------------------+--------+
$ openstack loadbalancer healthmonitor list
+--------------------------------------+------+----------------------------------+------+----------------+
| id                                   | name | project_id                       | type | admin_state_up |
+--------------------------------------+------+----------------------------------+------+----------------+
| 4bb27006-544f-43be-9748-e054559c3dc1 |      | 1810fe7db5e64e14a9edc01d093ef318 | HTTP | True           |
+--------------------------------------+------+----------------------------------+------+----------------+
$ openstack loadbalancer healthmonitor show 4bb27006-544f-43be-9748-e054559c3dc1
+---------------------+--------------------------------------+
| Field               | Value                                |
+---------------------+--------------------------------------+
| project_id          | 1810fe7db5e64e14a9edc01d093ef318     |
| name                |                                      |
| admin_state_up      | True                                 |
| pools               | 14ec7b1f-3d29-478e-a51b-01b3a6b33113 |
| created_at          | 2020-01-16T10:45:34                  |
| provisioning_status | ACTIVE                               |
| updated_at          | 2020-01-16T10:45:34                  |
| delay               | 5                                    |
| expected_codes      | 200                                  |
| max_retries         | 4                                    |
| http_method         | GET                                  |
| timeout             | 10                                   |
| max_retries_down    | 3                                    |
| url_path            | /healthcheck                         |
| type                | HTTP                                 |
| id                  | 4bb27006-544f-43be-9748-e054559c3dc1 |
| operating_status    | ONLINE                               |
+---------------------+--------------------------------------+
```

So it's seems that loadbalancer healthmonitor is looking for http://vm2/healthcheck file but can't find it. Which is a normal behavior regarding our stack server-stack created with 02-create_vms.yaml.

So let's fix that.

Create /var/www/html/healthcheck file on vm2 and check

```
$ ssh -o StrictHostKeyChecking=no centos@${vm2_ip} "echo \"HealthCheck\" | sudo tee /var/www/html/healthcheck; sudo chown apache: /var/www/html/healthcheck"
$ sleep 30
$ curl http://${lb_ip}
It Works for member: vm1
NAME   MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
vda    253:0    0  20G  0 disk
└─vda1 253:1    0  20G  0 part /
vdb    253:16   0  10G  0 disk
$ curl http://${lb_ip}
It Works for member: vm2
NAME   MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
vda    253:0    0  20G  0 disk
└─vda1 253:1    0  20G  0 part /
```

Now our loadbalancer is using vm1 and vm2 using our round robin algorithm.
