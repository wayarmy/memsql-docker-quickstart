#!/bin/bash
set -e
set -x

# Expects this file to export $OPS_VERSION and $MEMSQL_VERSION
export OPS_VERSION=5.8.2
export MEMSQL_VERSION=ae99ed27eb2ce5e9c07fba92f19bffe9823bdfd5

VERSION_URL="http://versions.memsql.com/memsql-ops/$OPS_VERSION"
MEMSQL_VOLUME_PATH="/memsql"
OPS_URL=$(curl -s "$VERSION_URL" | jq -r .tar)

# setup memsql user
groupadd -r memsql --gid 1000
useradd -r -g memsql -s /bin/false --uid 1000 \
    -d /var/lib/memsql-ops -c "MemSQL Service Account" \
    memsql

# download ops
curl -s $OPS_URL -o /tmp/memsql_ops.tar.gz

# install ops
mkdir /tmp/memsql-ops
tar -xzf /tmp/memsql_ops.tar.gz -C /tmp/memsql-ops --strip-components 1
/tmp/memsql-ops/install.sh \
    --host 127.0.0.1 \
    --no-cluster \
    --ops-datadir /memsql-ops \
    --memsql-installs-dir /memsql-ops/installs

DEPLOY_EXTRA_FLAGS=
if [[ $MEMSQL_VERSION != "developer" ]]; then
    DEPLOY_EXTRA_FLAGS="--version-hash $MEMSQL_VERSION"
fi
memsql-ops memsql-deploy --role leaf --license 35e6e509d157463fbf9d5b60d58e3301 --port 3307 --version-hash ae99ed27eb2ce5e9c07fba92f19bffe9823bdfd5

LEAF_ID=$(memsql-ops memsql-list --memsql-role=leaf -q)
LEAF_PATH=$(memsql-ops memsql-path $LEAF_ID)

# We need to clear the maximum-memory setting in the leaf's memsql.cnf otherwise
# when we move to another machine with a different amount of memory the memory
# imbalance nag will show up
memsql-ops memsql-update-config --key maximum_memory --delete $LEAF_ID


# setup mutable directories in the volume
function setup_node_dirs {
    local node_name=$1
    local node_id=$2
    local node_path=$3

    # update socket file
    memsql-ops memsql-update-config --key "socket" --value $node_path/memsql.sock $node_id

    mkdir -p /memsql/$node_name

    for tgt in data plancache tracelogs; do
        # update the volume template
        cp -r $node_path/$tgt /memsql/$node_name

        # symlink the dir
        rm -rf $node_path/$tgt
        ln -s $MEMSQL_VOLUME_PATH/$node_name/$tgt $node_path/$tgt
    done

    # clear the plancache
    rm -rf /memsql/$node_name/plancache/*
}

setup_node_dirs leaf $LEAF_ID $LEAF_PATH

chown -R memsql:memsql /memsql /memsql-ops

memsql-ops memsql-stop --all
memsql-ops stop

# cleanup
rm -rf /tmp/*
rm -rf /memsql-ops/data/cache/*
