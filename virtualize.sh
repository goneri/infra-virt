#!/bin/bash
#
# Copyright (C) 2015 eNovance SAS <licensing@enovance.com>
#
# Author: Frederic Lepied <frederic.lepied@enovance.com>
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

set -e
set -x

ORIG=$(cd $(dirname $0); pwd)
PREFIX=$USER

if [ $# != 2 ]; then
    echo "Usage: $0 <config-tools dir> <libvirt host>"
    echo
    echo "ex: $0 /home/config-tools 192.168.100.12"
    exit 1
fi

ctdir=$1
virthost=$2
platform=virt_platform.yml

[ -f ~/virtualizerc ] && source ~/virtualizerc


# Default values if not set by user env
TIMEOUT_ITERATION=${TIMEOUT_ITERATION:-"150"}
LOG_DIR=${LOG_DIR:-"$(pwd)/logs"}

SSHOPTS="-oBatchMode=yes -oCheckHostIP=no -oHashKnownHosts=no  -oStrictHostKeyChecking=no -oPreferredAuthentications=publickey  -oChallengeResponseAuthentication=no -oKbdInteractiveDevices=no -oUserKnownHostsFile=/dev/null -oControlPath=~/.ssh/control-%r@%h:%p -oControlMaster=auto -oControlPersist=30"

upload_logs() {
    [ -f ~/openrc ] || return

    source ~/openrc
    BUILD_PLATFORM=${BUILD_PLATFORM:-"unknown_platform"}
    CONTAINER=${CONTAINER:-"unknown_platform"}
    for path in /var/lib/edeploy/logs /var/log  /var/lib/jenkins/jobs/puppet/workspace; do
        mkdir -p ${LOG_DIR}/$(dirname ${path})
        scp $SSHOPTS -r root@$installserverip:$path ${LOG_DIR}/${path}
    done
    find ${LOG_DIR} -type f -exec chmod 644 '{}' \;
    find ${LOG_DIR} -type d -exec chmod 755 '{}' \;
    for file in $(find ${LOG_DIR} -type f -printf "%P\n"); do
        swift upload --object-name ${BUILD_PLATFORM}/${PREFIX}/$(date +%Y%m%d-%H%M)/${file} ${CONTAINER} ${LOG_DIR}/${file}
    done
    swift post -r '.r:*' ${CONTAINER}
    swift post -m 'web-listings: true' ${CONTAINER}
}

if [ -n "$SSH_AUTH_SOCK" ]; then
    ssh-add -L > pubfile
    pubfile=pubfile
else
    pubfile=~/.ssh/id_rsa.pub
fi


$ORIG/virtualizor.py "$platform" $virthost --replace --prefix ${PREFIX} --public_network nat --replace --pub-key-file $pubfile
mac=$(ssh root@$virthost cat /etc/libvirt/qemu/${PREFIX}_os-ci-test4.xml|xmllint --xpath 'string(/domain/devices/interface[last()]/mac/@address)' -)
installserverip=$(ssh $SSHOPTS root@$virthost "awk '/ ${mac} / {print \$3}' /var/lib/libvirt/dnsmasq/nat.leases"|head -n 1)

retry=0
while ! rsync -e "ssh $SSHOPTS" --quiet -av --no-owner top/ root@$installserverip:/; do
    if [ $((retry++)) -gt 300 ]; then
        echo "reached max retries"
	exit 1
    else
        echo "install-server ($installserverip) not ready yet. waiting..."
    fi
    sleep 10
    echo -n .
done

set -eux
scp $SSHOPTS ${ctdir}/extract-archive.sh ${ctdir}/functions root@$installserverip:/tmp

ssh $SSHOPTS root@$installserverip "
[ -d /var/lib/edeploy ] && echo -e 'RSERV=localhost\nRSERV_PORT=873' >> /var/lib/edeploy/conf"

ssh $SSHOPTS root@$installserverip /tmp/extract-archive.sh
ssh $SSHOPTS root@$installserverip rm /tmp/extract-archive.sh /tmp/functions
ssh $SSHOPTS root@$installserverip "ssh-keygen -y -f ~jenkins/.ssh/id_rsa >> ~jenkins/.ssh/authorized_keys"
ssh $SSHOPTS root@$installserverip service dnsmasq restart
ssh $SSHOPTS root@$installserverip service httpd restart
ssh $SSHOPTS root@$installserverip service rsyncd restart


ssh $SSHOPTS root@$installserverip "
. /etc/config-tools/config
retry=0
while true; do
    if [  \$retry -gt $TIMEOUT_ITERATION ]; then
        echo 'Timeout'
        exit 1
    fi
    ((retry++))
    for node in \$HOSTS; do
        sleep 1
        echo -n .
        ssh $SSHOPTS jenkins@\$node uname > /dev/null 2>&1|| continue 2
        # NOTE(Gonéri): on I.1.2.1, the ci.pem file is deployed through
        # cloud-init. Since we can use our own cloud-init files, this file
        # is not installed correctly.
        if [ -f /etc/ssl/certs/ci.pem ]; then
            scp $SSHOPTS /etc/ssl/certs/ci.pem root@\$node:/etc/ssl/certs/ci.pem || exit 1
        fi
    done
    break
done
"



while curl --silent http://$installserverip:8282/job/puppet/build|\
        grep "Your browser will reload automatically when Jenkins is read"; do
    sleep 1;
done


jenkins_log_file="/var/lib/jenkins/jobs/puppet/builds/1/log"
(
    ssh $SSHOPTS root@$installserverip "
while true; do
    [ -f $jenkins_log_file ] && tail -f $jenkins_log_file
    sleep 1
done"
) &
tail_job=$!

# Wait for the first job to finish
ssh $SSHOPTS root@$installserverip "
    while true; do
        test -f /var/lib/jenkins/jobs/puppet/builds/1/build.xml && break;
        sleep 1;
    done"

kill ${tail_job}

# Dump elasticsearch logs into ${LOG_DIR},
# upload_logs will update the dump in swift.
$ORIG/dumpelastic.py --url http://${installserverip}:9200 --output-dir ${LOG_DIR}

upload_logs

#ssh $SSHOPTS -A root@$installserverip configure.sh

# virtualize.sh ends here
