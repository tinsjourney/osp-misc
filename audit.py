#!/usr/bin/env python

# List all orphan object because of a deleted project

#    Instances
#    Networks
#    Routers
#    Subnets
#    Floating IP
#    Ports
#    Security groups

#    Glance Images
#    Volumes / Volume snapshots / Volume backups

import argparse
import os
import sys
import prettytable

from oslo_utils import encodeutils
from oslo_utils import importutils
from keystoneclient import session as ksc_session
from keystoneclient.auth.identity import v3

from keystoneclient.v3 import client as keystone_client
from neutronclient.v2_0 import client as neutron_client
from cinderclient.v2 import client as cinder_client
from glanceclient.v2 import client as glance_client
from novaclient import client as nova_client

# Define variables to connect to nova
if os.environ['OS_TENANT_NAME']:
    os_tenant_name = os.environ['OS_TENANT_NAME']
else:
    os_tenant_name = os.environ['OS_PROJECT_NAME']

auth = v3.Password(auth_url=os.environ['OS_AUTH_URL'],
                   username=os.environ['OS_USERNAME'],
                   password=os.environ['OS_PASSWORD'],
                   project_name=os_tenant_name,
                   user_domain_id='default',
                   project_domain_id='default')

session = ksc_session.Session(auth=auth)
#session = ksc_session..Session(auth=auth,verify='/path/to/ca.cert')
try:
    keystone = keystone_client.Client(session=session)
except Exception as e:
    raise e
try:
    nova = nova_client.Client("2.1", session=session)
except Exception as e:
    raise e
try:
    neutron = neutron_client.Client(session=session)
except Exception as e:
    raise e
try:
    cinder = cinder_client.Client(session=session)
except Exception as e:
    raise e
try:
    glance = glance_client.Client(session=session)
except Exception as e:
    raise e

def print_list(objs, fields, formatters={}):
    pt = prettytable.PrettyTable([f for f in fields], caching=False)
    pt.align = 'l'

    for o in objs:
        row = []
        for field in fields:
            if field in formatters:
                row.append(formatters[field](o))
            else:
                field_name = field.lower().replace(' ', '_')
                if type(o) == dict and field in o:
                    data = o[field_name]
                else:
                    data = getattr(o, field_name, None) or ''
                row.append(data)
        pt.add_row(row)

    print(encodeutils.safe_encode(pt.get_string()))

def get_projectids():
    return [project.id for project in keystone.projects.list()]

def nova_audit():
    # instance
    servers = nova.servers.list(search_opts={'all_tenants': True})
    zombie_servers = [s for s in servers if s.tenant_id not in projectids]
    if zombie_servers:
        print('>>>>>> ZOMBIE INSTANCE LIST')
        print_list(zombie_servers, ['id', 'name', 'tenant_id'])

def neutron_audit(neutron_obj):
    resource_name = neutron_obj
    neutron_objs = getattr(neutron, 'list_' + neutron_obj)()
    zombie = []
    for neutron_obj in neutron_objs.get(neutron_obj):
        if neutron_obj['tenant_id'] not in projectids and neutron_obj['tenant_id']:
            zombie.append(neutron_obj)
    if zombie:
        print('>>>>>> ZOMBIE '+resource_name.upper()+' LIST')
        print_list(zombie, ['id', 'name', 'tenant_id'])


def cinder_audit():
    # snapshots
    snapshots = cinder.volume_snapshots.list(search_opts={'all_tenants': True})
    tenant_attr = 'os-extended-snapshot-attributes:project_id'
    zombie_snapshots = [s for s in snapshots
                        if getattr(s, tenant_attr) not in projectids]
    if zombie_snapshots:
        print('>>>>>> ZOMBIE VOLUME SNAPSHOTS LIST')
        print_list(zombie_snapshots, ['id', 'display_name', 'status', tenant_attr])

    volumes = cinder.volumes.list(search_opts={'all_tenants': True})
    tenant_attr = 'os-vol-tenant-attr:tenant_id'
    zombie_volumes = [v for v in volumes
        if getattr(v, tenant_attr) not in projectids]
    if zombie_volumes:
        print('>>>>>> ZOMBIE VOLUME LIST')
        print_list(zombie_volumes, ['id', 'display_name',
                                'os-vol-tenant-attr:tenant_id'])

def glance_audit():
    # image
    images = glance.images.list()
    zombie_images = [i for i in images if (i.owner not in projectids)]
    if zombie_images:
        print('>>>>>> ZOMBIE IMAGE LIST')
        print_list(zombie_images, ['id', 'name', 'owner'])

if __name__ == '__main__':

    projectids = get_projectids()

    neutron_objs = ['networks','routers','subnets','floatingips','ports','security_groups']

    nova_audit()
    for neutron_obj in neutron_objs:
        neutron_audit(neutron_obj)
    cinder_audit()
    glance_audit()

# vim: set et sts=4 sw=4 tw=120 ft=python:
