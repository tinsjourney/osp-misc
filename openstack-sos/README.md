# Generate sosreport on Overcloud nodes and upload it to Red Hat Customer Portal

## How to use

Install Role

```
$ ansible-galaxy install -r requirements.yaml
```

Generate and upload sosreports from all Overcloud to case 01234567

```
$ ansible-playbook -i /usr/bin/tripleo-ansible-inventory openstack_sos.yaml -e "nodes=overcloud" -e "caseNumber=01234567"
```

Generate and upload sosreports from Controller only to case 01234567

```
$ ansible-playbook -i /usr/bin/tripleo-ansible-inventory openstack_sos.yaml -e "nodes=Controller" -e "caseNumber=01234567"
```

Generate and upload sosreports from Controller-0 and all Computes only to case 01234567

```
$ ansible-playbook -i /usr/bin/tripleo-ansible-inventory openstack_sos.yaml -e "nodes=overcloud-controller-0,Computes" -e "caseNumber=01234567"
```

## Advanced example

* Generate sosreport but do not upload to Red Hat
* Keep local sosreport
* Only upload local sosreport

```
  roles:
    - role: sosreport
      vars:
        - sosreport_options: ""
        - rhn_user: "my_user"
        - rhn_pass: "my_pass"
        - sosreport_delete_local_sosreports: false
        - upload: false
```

```
  tasks:
    - ansible.builtin.include_role:
        name: sosreport
        tasks_from: push.yml
      vars:
        - rhn_user: "my_user"
        - rhn_pass: "my_pass"
```
