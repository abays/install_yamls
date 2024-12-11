#!/bin/bash

if [ -z "$DEPLOY_DIR" ]; then
    echo "Please set DEPLOY_DIR"; exit 1
fi

if [ -z "$NNCP_CLEANUP_TIMEOUT" ]; then
    echo "Please set NNCP_CLEANUP_TIMEOUT"; exit 1
fi

if [ -z "$NNCP_INTERFACE" ]; then
    echo "Please set NNCP_INTERFACE"; exit 1
fi

# We should only set existing NNCPs in the cluster to "absent" (so as to unconfigure them)
# if they have actually succeeded in being configured in the first place.  Otherwise NMState
# has not actually changed the OCP nodes and the "absent" directive is a waste of time.  In
# such a scenario, we have also seen the "absent" logic introduce connectivity issues, so
# avoiding it might be beneficial.
for i in "${DEPLOY_DIR}"/*_nncp.yaml; do 
    NNCP_NAME=$(yq '.metadata.name' "${i}")
    NNCP_STATE=$(oc get nncp "${NNCP_NAME}" -o json | jq -r '.status.conditions[0].reason')

    # If we find that this NNCP has been successfully configured, we want to set its state
    # to "absent" so as to remove its configuration from the OCP node.

    if [ "${NNCP_STATE}" == "SuccessfullyConfigured" ]; then
        sed -i 's/state: up/state: absent/' "${i}"
	    oc apply -f "${i}"
	    oc wait nncp "${NNCP_NAME}" --for condition=available --timeout=${NNCP_CLEANUP_TIMEOUT}
    fi
done

# Now we can delete all the NNCPs
oc delete --ignore-not-found=true -f "${DEPLOY_DIR}/"
