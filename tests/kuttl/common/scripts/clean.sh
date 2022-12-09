#!/bin/bash

SERVICES=(cinder glance ironic neutron nova octavia ovn placement)

#
# Clean the field to help avoid false positives and negatives
#
MAKE_CMD="make"

# Try deleting any OpenStackControlPlanes first
NAMESPACE=openstack $MAKE_CMD openstack_deploy_cleanup

# Now delete individual service operators, minus Keystone
for i in "${SERVICES[@]}"
do
    NAMESPACE=openstack $MAKE_CMD ${i}_deploy_cleanup
done

sleep 3

# Now delete Keystone
NAMESPACE=openstack $MAKE_CMD keystone_deploy_cleanup

sleep 3

# Finally delete MariaDB
NAMESPACE=openstack $MAKE_CMD mariadb_deploy_cleanup

#
# ...also clear events for good measure :)
#
oc delete events --all -n openstack
