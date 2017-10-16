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
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
########################################################################

#######################################################################
#
# sriov-perf_iperf_server.sh
#
# Description:
#     For the test to run you have to place the iperf3 tool package in the
#     Tools folder under lisa.
#
# Requirements:
#   The sar utility must be installed, package named sysstat
#
# Parameters:
#     IPERF_PACKAGE: the iperf3 tool package
#     INDIVIDUAL_TEST_DURATION: the test duration of each iperf3 test
#     CONNECTIONS_PER_IPERF3: how many iPerf connections will be created by iPerf3 client to a single iperf3 server
#     TEST_SIGNAL_FILE: the signal file send by client side to sync up the number of test connections
#     TEST_RUN_LOG_FOLDER: the log folder name. sar log and top log will be saved in this folder for further analysis
#
#######################################################################

ICA_TESTRUNNING="TestRunning"
ICA_IPERF3RUNNING="iPerf3Running"
ICA_TESTCOMPLETED="TestCompleted"
ICA_TESTABORTED="TestAborted"
ICA_TESTFAILED="TestFailed"

LogMsg()
{
    echo `date "+%a %b %d %T %Y"` ": ${1}"
}

UpdateTestState()
{
    echo $1 > ~/state.txt
}

#######################################################################
#
# Main script body
#
#######################################################################

cd ~
UpdateTestState $ICA_TESTRUNNING
LogMsg "Starting running the script"

#
# Delete any old summary.log file
#
LogMsg "Cleaning up old summary.log"
if [ -e ~/summary.log ]; then
    rm -f ~/summary.log
fi

touch ~/summary.log

# Convert eol
dos2unix utils.sh

# Source utils.sh
. utils.sh || {
    echo "Error: unable to source utils.sh!"
    echo "TestAborted" > state.txt
    exit 2
}

# Source constants file and initialize most common variables
UtilsInit

# In case of error
case $? in
    0)
        #do nothing, init succeeded
        ;;
    1)
        LogMsg "Unable to cd to $LIS_HOME. Aborting..."
        UpdateSummary "Unable to cd to $LIS_HOME. Aborting..."
        SetTestStateAborted
        exit 3
        ;;
    2)
        LogMsg "Unable to use test state file. Aborting..."
        UpdateSummary "Unable to use test state file. Aborting..."
        # need to wait for test timeout to kick in
        # hailmary try to update teststate
        sleep 60
        echo "TestAborted" > state.txt
        exit 4
        ;;
    3)
        LogMsg "Error: unable to source constants file. Aborting..."
        UpdateSummary "Error: unable to source constants file"
        SetTestStateAborted
        exit 5
        ;;
    *)
        # should not happen
        LogMsg "UtilsInit returned an unknown error. Aborting..."
        UpdateSummary "UtilsInit returned an unknown error. Aborting..."
        SetTestStateAborted
        exit 6
        ;;
esac

#
# Make sure the required test parameters are defined
#
if [ "${IPERF_PACKAGE:="UNDEFINED"}" = "UNDEFINED" ]; then
    msg="Error: the IPERF_PACKAGE test parameter is missing"
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
    UpdateTestState $ICA_TESTFAILED
    exit 20
fi

if [ "${IPERF3_PROTOCOL:="UNDEFINED"}" = "UNDEFINED" ]; then
    msg="Info: no IPERF3_PROTOCOL was specified, assuming default TCP"
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
fi

if [ "${INDIVIDUAL_TEST_DURATION:="UNDEFINED"}" = "UNDEFINED" ]; then
    INDIVIDUAL_TEST_DURATION=600
    msg="Error: the INDIVIDUAL_TEST_DURATION test parameter is missing and the default value will be used: ${INDIVIDUAL_TEST_DURATION}."
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
fi

if [ "${CONNECTIONS_PER_IPERF3:="UNDEFINED"}" = "UNDEFINED" ]; then
    CONNECTIONS_PER_IPERF3=4
    msg="Error: the CONNECTIONS_PER_IPERF3 test parameter is missing and the default value will be used: ${CONNECTIONS_PER_IPERF3}."
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
fi

if [ "${TEST_SIGNAL_FILE:="UNDEFINED"}" = "UNDEFINED" ]; then
    TEST_SIGNAL_FILE="~/iperf3.test.sig"
    msg="Warning: the TEST_SIGNAL_FILE test parameter is missing and the default value will be used: ${TEST_SIGNAL_FILE}."
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
fi

if [ "${TEST_RUN_LOG_FOLDER:="UNDEFINED"}" = "UNDEFINED" ]; then
    TEST_RUN_LOG_FOLDER="iperf3-server-logs"
    msg="Warning: the TEST_RUN_LOG_FOLDER test parameter is is missing and the default value will be used:${TEST_RUN_LOG_FOLDER}"
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
fi

# Extract the files from the IPerf tar package
#
tar -xzf ./${IPERF_PACKAGE}
if [ $? -ne 0 ]; then
    msg="Error: Unable extract ${IPERF_PACKAGE}"
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
    UpdateTestState $ICA_TESTFAILED
    exit 70
fi


CheckIPV6 "$BOND_IP2"
if [[ $? -eq 0 ]]; then
    ipVersion="-6"
else
    ipVersion="-4"
fi

#
# Get the root directory of the tarball
#
rootDir=`tar -tzf ${IPERF_PACKAGE} | sed -e 's@/.*@@' | uniq`
if [ -z ${rootDir} ]; then
    msg="Error: Unable to determine iperf3's root directory"
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
    UpdateTestState $ICA_TESTFAILED
    exit 80
fi

LogMsg "rootDir = ${rootDir}"
cd ${rootDir}

#
# Distro specific setup
#
iptables -F
ip6tables -F
GetDistro

case "$DISTRO" in
debian*|ubuntu*)
    LogMsg "Updating apt repositories"
    apt-get update & wait

    LogMsg "Installing sar on Ubuntu"
    apt-get install sysstat -y
    if [ $? -ne 0 ]; then
        msg="Error: sysstat failed to install"
        LogMsg "${msg}"
        echo "${msg}" >> ~/summary.log
        UpdateTestState $ICA_TESTFAILED
        exit 85
    fi
    apt-get install zip build-essential -y
    if [ $? -ne 0 ]; then
        msg="Error: Build essential failed to install"
        LogMsg "${msg}"
        echo "${msg}" >> ~/summary.log
        UpdateTestState $ICA_TESTFAILED
        exit 85
    fi
    service ufw status
    if [ $? -ne 3 ]; then
        LogMsg "Disabling firewall on Ubuntu"
        service ufw stop
        if [ $? -ne 0 ]; then
                msg="Error: Failed to stop ufw"
                LogMsg "${msg}"
                echo "${msg}" >> ~/summary.log
        fi
    fi
    ;;
redhat_5|redhat_6|centos_6|centos_5)
    LogMsg "Check irqbalance status on RHEL 5/6.x."
    service irqbalance status
    if [ $? -eq 3 ]; then
        LogMsg "Enabling irqbalance on Redhat 5/6.x"
        service irqbalance start
        if [ $? -ne 0 ]; then
            msg="ERROR: Failed to start irqbalance. Failing."
            LogMsg "${msg}"
            echo "${msg}" >> ~/summary.log
            UpdateTestState $ICA_TESTFAILED
            exit 1
        fi
    fi
    disable_firewall
    if [[ $? -ne 0 ]]; then
        msg="ERROR: Unable to disable firewall.Exiting"
        LogMsg "${msg}"
        echo "${msg}" >> ~/summary.log
        UpdateTestState $ICA_TESTFAILED
        exit 1
    fi
    ;;
redhat_7|centos_7)
    LogMsg "Check irqbalance status on RHEL 7.xx."
    systemctl status irqbalance
    if [ $? -eq 3 ]; then
        LogMsg "Enabling irqbalance on Redhat 7.x"
        systemctl enable irqbalance && systemctl start irqbalance
        if [ $? -ne 0 ]; then
            msg="ERROR: Failed to start irqbalance. Failing."
            LogMsg "${msg}"
            echo "${msg}" >> ~/summary.log
            UpdateTestState $ICA_TESTFAILED
            exit 1
        fi
    fi
    LogMsg "Check iptables status on RHEL"
    systemctl status firewalld
    if [ $? -ne 3 ]; then
        LogMsg "Disabling firewall on Redhat 7"
        systemctl disable firewalld
        if [ $? -ne 0 ]; then
            msg="Error: Failed to stop firewalld"
            LogMsg "${msg}"
            echo "${msg}" >> ~/summary.log
            UpdateTestState $ICA_TESTFAILED
            exit 85
        fi
        systemctl stop firewalld
        if [ $? -ne 0 ]; then
            msg="Error: Failed to turn off firewalld. Continuing"
            LogMsg "${msg}"
            echo "${msg}" >> ~/summary.log
        fi
    fi

    LogMsg "Check iptables status on RHEL7"
    service iptables status
    if [ $? -ne 3 ]; then
        iptables -F;
        if [ $? -ne 0 ]; then
            msg="Error: Failed to flush iptables rules. Continuing"
            LogMsg "${msg}"
            echo "${msg}" >> ~/summary.log
        fi
        chkconfig iptables off
        if [ $? -ne 0 ]; then
            msg="Error: Failed to turn off iptables. Continuing"
            LogMsg "${msg}"
            echo "${msg}" >> ~/summary.log
        fi
    fi
    ;;
suse_12)
	#
	# Install gcc which is required to build iperf3
	#
	zypper --non-interactive install gcc

    LogMsg "Check iptables status on RHEL7"
    service SuSEfirewall2 status
    if [ $? -ne 3 ]; then
        iptables -F;
        if [ $? -ne 0 ]; then
            msg="Error: Failed to flush iptables rules. Continuing"
            LogMsg "${msg}"
            echo "${msg}" >> ~/summary.log
        fi
        service SuSEfirewall2 stop
        if [ $? -ne 0 ]; then
            msg="Error: Failed to stop iptables"
            LogMsg "${msg}"
            echo "${msg}" >> ~/summary.log
            UpdateTestState $ICA_TESTFAILED
            exit 85
        fi
        chkconfig SuSEfirewall2 off
        if [ $? -ne 0 ]; then
            msg="Error: Failed to turn off iptables. Continuing"
            LogMsg "${msg}"
            echo "${msg}" >> ~/summary.log
        fi
    fi
    ;;
esac

#
# Build iperf
#
./configure
if [ $? -ne 0 ]; then
    msg="Error: ./configure failed"
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
    UpdateTestState $ICA_TESTFAILED
    exit 90
fi

make
if [ $? -ne 0 ]; then
    msg="Error: Unable to build iperf"
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
    UpdateTestState $ICA_TESTFAILED
    exit 100
fi

make install
if [ $? -ne 0 ]; then
    msg="Error: Unable to install iperf"
    LogMsg "${msg}"
    echo "${msg}" >> ~/summary.log
    UpdateTestState $ICA_TESTFAILED
    exit 110
fi

if [ $DISTRO -eq "suse_12" ]; then
    ldconfig
    if [ $? -ne 0 ]; then
        msg="Warning: Couldn't run ldconfig, there might be shared library errors"
        LogMsg "${msg}"
        echo "${msg}" >> ~/summary.log
    fi
fi

# go back to test root folder
cd ~

# Start iPerf3 server instances
#
LogMsg "Starting iPerf3 in server mode"

UpdateTestState $ICA_IPERF3RUNNING
LogMsg "iperf3 server instances now are ready to run"

mkdir ${TEST_RUN_LOG_FOLDER}
#default the parameter
number_of_connections=0
touch ${TEST_SIGNAL_FILE}
echo 0 > ${TEST_SIGNAL_FILE}

time=0
while true; do
    #once received a reset/start signal from client side, do the test
    if [ -f ${TEST_SIGNAL_FILE} ];
    then
        number_of_connections=$(head -n 1 ${TEST_SIGNAL_FILE})
        rm -rf ${TEST_SIGNAL_FILE}
        echo "Reset iperf3 server for test. Connections: ${number_of_connections} ..."
        pkill -f iperf3
        sleep 1

        echo "Start new iperf3 instances..."
        number_of_iperf_instances=$((number_of_connections/CONNECTIONS_PER_IPERF3+8001))

        for ((i=8001; i<=$number_of_iperf_instances; i++))
        do
            /root/${rootDir}/src/iperf3 -s $ipVersion -p $i -i ${INDIVIDUAL_TEST_DURATION} -D
            sleep 1
        done
        x=$(ps -aux | grep iperf | wc -l)
        echo "ps -aux | grep iperf | wc -l: $x"

        mkdir ./${TEST_RUN_LOG_FOLDER}/$number_of_connections

        sar -n DEV 1 ${INDIVIDUAL_TEST_DURATION} 2>&1 > ./${TEST_RUN_LOG_FOLDER}/$number_of_connections/sar.log &
    fi

    top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}' >> ./${TEST_RUN_LOG_FOLDER}/$number_of_connections/top.log
    #ifstat eth0 | grep eth0 | awk '{print $6}' >> ifstatlog.log
    if [ $(($time % 10)) -eq 0 ];
    then
        echo $(netstat -nat | grep ESTABLISHED | wc -l) >> ./${TEST_RUN_LOG_FOLDER}/$number_of_connections/connections.log
    fi

    sleep 1
    time=$(($time + 1))
    echo "$time"
done
