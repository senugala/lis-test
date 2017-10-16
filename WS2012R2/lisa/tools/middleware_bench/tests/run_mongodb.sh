#!/bin/bash

########################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved.
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABILITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
########################################################################

LOG_FILE=/tmp/summary.log
function LogMsg() {
    echo $(date "+%a %b %d %T %Y") : ${1} >> ${LOG_FILE}
}

if [ $# -lt 3 ]; then
    echo -e "\nUsage:\n$0 server user ebs_vol"
    exit 1
fi

SERVER="$1"
USER="$2"
DISK="$3"
TEST_THREADS=(1 2 4 8 16 32 64 128)
workload="/tmp/LISworkload"
ycsb="/tmp/ycsb-0.11.0/bin/ycsb"

if [ -e /tmp/summary.log ]; then
    rm -rf /tmp/summary.log
fi

if [[ ${DISK} == *"xvd"* || ${DISK} == *"sd"* ]]
then
    db_path="/mongo/db"
    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo mkdir -p ${db_path}"
    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo mkfs.ext4 ${DISK}" >> ${LOG_FILE}
    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo mount ${DISK} ${db_path}" >> ${LOG_FILE}
elif [[ ${DISK} == *"md"* ]]
then
    db_path="/raid/mongo/db"
    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo mkdir -p ${db_path}"
else
    LogMsg "Failed to identify disk type for ${DISK}."
    exit 70
fi

escaped_path=$(echo "${db_path}" | sed 's/\//\\\//g')
distro="$(head -1 /etc/issue)"
if [[ ${distro} == *"Ubuntu"* ]]
then
    sudo apt -y install libaio1 sysstat zip curl python default-jdk >> ${LOG_FILE}
    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo apt -y install libaio1 sysstat zip mongodb-server" >> ${LOG_FILE}
    db_conf="/etc/mongodb.conf"
    db_service="mongodb"
elif [[ ${distro} == *"Amazon"* ]]
then
    sudo yum clean dbcache >> ${LOG_FILE}
    sudo yum -y install sysstat zip sysstat zip automake openssl-devel gcc libtool curl >> ${LOG_FILE}
    mongo_repo_server="[mongodb-org-2.6]\
                       \nname=MongoDB 2.6 Repository\
                       \nbaseurl=http://downloads-distro.mongodb.org/repo/redhat/os/x86_64\
                       \ngpgcheck=0\
                       \nenabled=1"
    echo -e ${mongo_repo_server} | sudo tee /etc/yum.repos.d/mongodb.repo >> ${LOG_FILE}
    sudo yum -y install mongodb-org-tools >> ${LOG_FILE}
    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo yum clean dbcache" >> ${LOG_FILE}
    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "echo -e '${mongo_repo_server}' | sudo tee /etc/yum.repos.d/mongodb.repo" >> ${LOG_FILE}
    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo yum -y install openssl-devel sysstat zip mongodb-org" >> ${LOG_FILE}
    db_conf="/etc/mongod.conf"
    db_service="mongod"
else
    LogMsg "Unsupported distribution: ${distro}."
fi

cd /tmp
curl -O --location https://github.com/brianfrankcooper/YCSB/releases/download/0.11.0/ycsb-0.11.0.tar.gz
tar xfvz ycsb-0.11.0.tar.gz
sudo pkill -f ycsb

#Generating custom LIS workload
echo -e "recordcount=20000000\noperationcount=20000000\nreadallfields=true\nwriteallfields=false\nworkload=com.yahoo.ycsb.workloads.CoreWorkload\nreadproportion=0.5\nupdateproportion=0.5\nrequestdistribution=zipfian\nthreadcount=8\nmaxexecutiontime=900" >> ${workload}

mkdir -p /tmp/mongodb
ssh -o StrictHostKeyChecking=no ${USER}@${SERVER} "mkdir -p /tmp/mongodb"

ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo service ${db_service} stop" >> ${LOG_FILE}
ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo chown -R ${db_service}:${db_service} ${db_path}"
ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo sed -i '/dbpath/c\dbpath=${escaped_path}' ${db_conf}" >> ${LOG_FILE}
ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo sed -i '/bind_ip/c\bind_ip = 0\.0\.0\.0' ${db_conf}" >> ${LOG_FILE}
ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo service ${db_service} start" >> ${LOG_FILE}

# Wait for mongo server to create its artifacts at the new location
sleep 60

${ycsb} load mongodb-async -s -P ${workload} -p mongodb.url=mongodb://${SERVER}:27017/ycsb?w=0 >> ${LOG_FILE}

function run_mongodb ()
{
    threads=$1

    LogMsg "======================================"
    LogMsg "Running mongodb test with current threads: ${threads}"
    LogMsg "======================================"

    ssh -f -o StrictHostKeyChecking=no ${USER}@${SERVER} "sar -n DEV 1 900   2>&1 > /tmp/mongodb/${threads}.sar.netio.log"
    ssh -f -o StrictHostKeyChecking=no ${USER}@${SERVER} "iostat -x -d 1 900 2>&1 > /tmp/mongodb/${threads}.iostat.diskio.log"
    ssh -f -o StrictHostKeyChecking=no ${USER}@${SERVER} "vmstat 1 900       2>&1 > /tmp/mongodb/${threads}.vmstat.memory.cpu.log"
    sar -n DEV 1 900   2>&1 > /tmp/mongodb/${threads}.sar.netio.log &
    iostat -x -d 1 900 2>&1 > /tmp/mongodb/${threads}.iostat.netio.log &
    vmstat 1 900       2>&1 > /tmp/mongodb/${threads}.vmstat.netio.log &

    ${ycsb} run mongodb-async -s -P ${workload} -p mongodb.url=mongodb://${SERVER}:27017/ycsb?w=0 -threads ${threads} > /tmp/mongodb/${threads}.ycsb.run.log

    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo pkill -f sar"
    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo pkill -f iostat"
    ssh -T -o StrictHostKeyChecking=no ${USER}@${SERVER} "sudo pkill -f vmstat"
    sudo pkill -f sar
    sudo pkill -f iostat
    sudo pkill -f vmstat

    LogMsg "sleep 60 seconds"
    sleep 60
}

for threads in "${TEST_THREADS[@]}"
do
    run_mongodb ${threads}
done

LogMsg "Kernel Version : `uname -r`"
LogMsg "Guest OS : ${distro}"

cd /tmp
zip -r mongodb.zip . -i mongodb/* >> ${LOG_FILE}
zip -r mongodb.zip . -i summary.log >> ${LOG_FILE}
