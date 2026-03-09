#!/bin/bash
#
# Copyright 2026 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
set -ex

if [ -z "${OUT_DIR}" ]; then
    echo "Please set OUT_DIR"; exit 1
fi

KRBAC_PROXY_SRC=${KRBAC_PROXY_SRC:-"gcr.io/kubebuilder/kube-rbac-proxy"}
KRBAC_PROXY_DEST=${KRBAC_PROXY_DEST:-"quay.io/openstack-k8s-operators/kube-rbac-proxy"}

mkdir -p ${OUT_DIR}

cat > ${OUT_DIR}/digest-mirror-set.yaml <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: redirect-kube-rbac-proxy-digests
spec:
  imageDigestMirrors:
  - mirrors:
    - ${KRBAC_PROXY_DEST}
    source: ${KRBAC_PROXY_SRC}
EOF

cat > ${OUT_DIR}/tag-mirror-set.yaml <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: redirect-kube-rbac-proxy-tags
spec:
  imageTagMirrors:
  - mirrors:
    - ${KRBAC_PROXY_DEST}
    source: ${KRBAC_PROXY_SRC}
EOF

oc apply -f ${OUT_DIR}
