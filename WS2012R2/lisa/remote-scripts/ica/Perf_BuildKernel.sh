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
# Description:
#     This script was created to automate the testing of a Linux
#     kernel source tree.  It does this by performing the following
#     steps:
#    1. Make sure we were given a kernel source. If a linux-next git address is provided, make sure that
#       the VM has a NIC (eth1) connect to Internet. This script will configure eth1 to DHCP to access internet.
#    2. Configure and build the new kernel
#
# The outputs are directed into files named:
#     Perf_BuildKernel_make.log, 
#     Perf_BuildKernel_makemodulesinstall.log, 
#     Perf_BuildKernel_makeinstall.log
#
# This test script requires the below test parameters:
#     <param>SOURCE_TYPE=ONLINE</param>
#     <param>LINUX_KERNEL_LOCATION=git://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git</param>
#     <param>KERNEL_VERSION=linux-next</param>
#
# A typical XML test definition for this test case would look
# similar to the following:
#          <test>
#             <testName>TimeBuildKernel</testName>     
#             <testScript>Perf_BuildKernel.sh</testScript>
#             <files>remote-scripts/ica/Perf_BuildKernel.sh</files>
#             <files>Tools/linux-3.14.tar.xz</files>
#             <testParams>
#                 <param>SOURCE_TYPE=ONLINE</param>
#                 <param>LINUX_KERNEL_LOCATION=https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git</param>
#                 <param>KERNEL_VERSION=linux-next</param>
#                 <param>ACTIVATE_GCOV=yes</param>
#             </testParams>
#             <uploadFiles>
#                 <file>Perf_BuildKernel_make.log</file>
#                 <file>Perf_BuildKernel_makemodulesinstall.log</file> 
#                 <file>Perf_BuildKernel_makeinstall.log</file>
#             </uploadFiles>
#             <timeout>10800</timeout>
#             <OnError>Abort</OnError>
#          </test>
#
#######################################################################



DEBUG_LEVEL=3
CONFIG_FILE=.config

START_DIR=$(pwd)
cd ~

#
# Source the constants.sh file so we know what files to operate on.
#

source ./constants.sh

function EnableGcov()
{
    FILE=`readlink -e $1`
    NR_GCOV=`grep -n "GCOV-based" newconf | grep -Eo '^[^:]+'`
    NR_GCOV=$(($NR_GCOV + 2))

    GCOV_LINES="CONFIG_GCOV_KERNEL=y\n\
CONFIG_ARCH_HAS_GCOV_PROFILE_ALL=y\n\
CONFIG_GCOV_PROFILE_ALL=y\n\
CONFIG_GCOV_FORMAT_AUTODETECT=y\n\
# CONFIG_GCOV_FORMAT_3_4 is not set\n\
# CONFIG_GCOV_FORMAT_4_7 is not set"

    sed -i '/.*_GCOV_.*/ d' $FILE
    sed -i "${NR_GCOV}i ${GCOV_LINES}" $FILE
}

dbgprint()
{
    if [ $1 -le $DEBUG_LEVEL ]; then
        echo "$2"
    fi
}

UpdateTestState()
{
    echo $1 > ~/state.txt
}

UpdateSummary()
{
    echo $1 >> ~/summary.log
}

#
# Create the state.txt file so the ICA script knows
# we are running
#
UpdateTestState "TestRunning"
if [ -e ~/state.txt ]; then
    dbgprint 0 "State.txt file is created "
    dbgprint 0 "Content of state is : " ; echo `cat state.txt`
fi

#
# Write some useful info to the log file
#
dbgprint 1 "buildKernel.sh - Script to automate building of the kernel"
dbgprint 3 ""
dbgprint 3 "Global values"
dbgprint 3 "  DEBUG_LEVEL = ${DEBUG_LEVEL}"
dbgprint 3 "  SOURCE_TYPE = ${SOURCE_TYPE}"
dbgprint 3 "  LINUX_KERNEL_LOCATION = ${LINUX_KERNEL_LOCATION}"
dbgprint 3 "  TARBALL = ${TARBALL}"
dbgprint 3 "  KERNEL_VERSION = ${KERNEL_VERSION}"
dbgprint 3 "  CONFIG_FILE = ${CONFIG_FILE}"
dbgprint 3 ""

#
# Delete old kernel source tree if it exists.
# This should not be needed, but check to make sure
# 
# adding check for summary.log
if [ -e ~/summary.log ]; then
    dbgprint 1 "Cleaning up previous copies of summary.log"
    rm -rf ~/summary.log
fi
# adding check for old kernel source tree
if [ -e ${KERNEL_VERSION} ]; then
    dbgprint 1 "Cleaning up previous copies of source tree"
    dbgprint 3 "Removing the ${KERNEL_VERSION} directory"
    rm -rf ${KERNEL_VERSION}
fi

if [ "${SOURCE_TYPE}" == "ONLINE_TAR" ]; then
    
    wget ${LINUX_KERNEL_LOCATION}
    sts=$?
    if [ 0 -ne ${sts} ]; then
        dbgprint 0 "wget failed to download the kernel from the link: ${sts}" 
        dbgprint 0 "Aborting test."
        UpdateTestState "TestAborted"
        exit 40
    fi
    HTTP_TAR="${KERNEL_VERSION}.tar.xz"
    if [ -e "${HTTP_TAR}" ];then
        tar -xf ${HTTP_TAR}
        sts=$?
        if [ 0 -ne ${sts} ]; then
            dbgprint 0 "tar failed to extract the kernel from the tarball: ${sts}" 
            dbgprint 0 "Aborting test."
            UpdateTestState "TestAborted"
            exit 40
        fi
    else
        dbgprint 0 "the scrpit cannot find the tarball"
        UpdateTestState "TestAborted"
        exit 40
    fi
    
    if [ ! -e ${KERNEL_VERSION} ]; then
        dbgprint 0 "The tar file did not create the directory: ${KERNEL_VERSION}"
        dbgprint 0 "Aborting the test."
        UpdateTestState "TestAborted"
        exit 50
    fi
elif [ "${SOURCE_TYPE}" == "TARBALL" ]; then
    dbgprint 1 "Building linux kernel from tarball..."
    #
    # Make sure we were given the $TARBALL file
    #
    if [ ! ${TARBALL} ]; then
        dbgprint 0 "The TARBALL variable is not defined."
        dbgprint 0 "Aborting the test."
        UpdateTestState "TestAborted"
        exit 20
    fi

    dbgprint 3 "Extracting Linux kernel sources from ${TARBALL}"
    tar -xf ${TARBALL}
    sts=$?
    if [ 0 -ne ${sts} ]; then
        dbgprint 0 "tar failed to extract the kernel from the tarball: ${sts}" 
        dbgprint 0 "Aborting test."
        UpdateTestState "TestAborted"
        exit 40
    fi

    #
    # The Linux Kernel is extracted to the folder which is named by the version by default
    #
    if [ ! -e ${KERNEL_VERSION} ]; then
        dbgprint 0 "The tar file did not create the directory: ${KERNEL_VERSION}"
        dbgprint 0 "Aborting the test."
        UpdateTestState "TestAborted"
        exit 50
    fi
else
    dbgprint 1 "Building linux-next kernel from git repository..."
    #
    # Make sure we were given the linux-next git location
    #
    if [ ! ${LINUX_KERNEL_LOCATION} ]; then
        dbgprint 0 "The LINUX_KERNEL_LOCATION variable is not defined."
        dbgprint 0 "Aborting the test."
        UpdateTestState "TestAborted"
        exit 20
    fi
    
    # for SUSE, config the /etc/sysconfig/network/ifcfg-eth1 file to enable DHCP
    # dhclient eth1 does not work?
    SUSE_ETH0_CONFIG=/etc/sysconfig/network/ifcfg-eth0
    SUSE_ETH1_CONFIG=/etc/sysconfig/network/ifcfg-eth1
    cp ${SUSE_ETH0_CONFIG} ${SUSE_ETH1_CONFIG}
    sed --in-place -e s:"^BOOTPROTO='static'":"BOOTPROTO='dhcp'": ${SUSE_ETH1_CONFIG}
    sed --in-place -e s:"^IPADDR='.*'":"IPADDR=''": ${SUSE_ETH1_CONFIG}
    # start network of eth1 for internet access
    ifdown eth1
    ifup eth1
    
    zypper --non-interactive install git-core
    git clone ${LINUX_KERNEL_LOCATION}
fi

#
# Try apply patches under /root/
#
cd ${KERNEL_VERSION}
dbgprint 1 "*************************"
for patchfile in `ls ../*.patch`; do patch -f -p1 < $patchfile; done
dbgprint 1 "*************************"

#
# Start the testing
#
proc_count=$(cat /proc/cpuinfo | grep --count processor)
dbgprint 1 "Build kernel with $proc_count CPU(s)"

UpdateSummary "KernelRelease=$(uname -r)"
UpdateSummary "ProcessorCount=$proc_count"

UpdateSummary "$(uname -a)"

#
# Create the .config file
#
dbgprint 1 "Creating the .config file."
if [ -f ~/ica/kernel.config.base ]; then
    # Basing a new kernel config on a previous kernel config file will
    # provide flexibility in providing know good config files with certain
    # options enabled/disabled.  Functionality could also potentially be
    # added here for choosing between multiple old config files depending
    # on the distro that the kernel is being compiled on (i.g. if Fedora
    # is detected copy ~/ica/kernel.config.base-fedora to .config before
    # running 'make oldconfig')

    dbgprint 3 "Creating new config based on a previous .config file"
    cp ~/ica/kernel.config.base .config

    # Base the new config on the old one and select the default config
    # option for any new options in the newer kernel version
    yes "" | make oldconfig
else
    dbgprint 3 "Create a default .config file"
    yes "" | make oldconfig
    sts=$?
    if [ 0 -ne ${sts} ]; then
        dbgprint 0 "make defconfig failed."
        dbgprint 0 "Aborting the test."
        UpdateTestState "TestAborted"
        exit 60
    fi

    if [ ! -e ${CONFIG_FILE} ]; then
        dbgprint 0 "make defconfig did not create the '${CONFIG_FILE}'"
        dbgprint 0 "Aborting the test."
        UpdateTestState "TestAborted"
        exit 70
    fi

    #
    # Enable HyperV support
    #
    dbgprint 3 "Enabling HyperV support in the ${CONFIG_FILE}"
    # On this first 'sed' command use --in-place=.orig to make a backup
    # of the original .config file created with 'defconfig'
    sed --in-place=.orig -e s:"# CONFIG_HYPERVISOR_GUEST is not set":"CONFIG_HYPERVISOR_GUEST=y\nCONFIG_HYPERV=y\nCONFIG_HYPERV_UTILS=y\nCONFIG_HYPERV_BALLOON=y\nCONFIG_HYPERV_STORAGE=y\nCONFIG_HYPERV_NET=y\nCONFIG_HYPERV_KEYBOARD=y\nCONFIG_FB_HYPERV=y\nCONFIG_HID_HYPERV_MOUSE=y": ${CONFIG_FILE}

    # Disable kernel preempt support , because of this lot of stack trace is coming and some time kernel does not boot at all.
    #
    dbgprint 3 "Disabling KERNEL_PREEMPT_VOLUNTARY in ${CONFIG_FILE}"
    # On this first this is a workaround for known bug that makes kernel lockup once the bug is fixed we can remove this in PS bug ID is 124 and 125
    sed --in-place -e s:"CONFIG_PREEMPT_VOLUNTARY=y":"# CONFIG_PREEMPT_VOLUNTARY is not set": ${CONFIG_FILE}

    #
    # Enable Ext4, Reiser support (ext3 is enabled by default)
    #
    sed --in-place -e s:"# CONFIG_EXT4_FS is not set":"CONFIG_EXT4_FS=y\nCONFIG_EXT4_FS_XATTR=y\nCONFIG_EXT4_FS_POSIX_ACL=y\nCONFIG_EXT4_FS_SECURITY=y": ${CONFIG_FILE}
    sed --in-place -e s:"# CONFIG_REISERFS_FS is not set":"CONFIG_REISERFS_FS=y\nCONFIG_REISERFS_PROC_INFO=y\nCONFIG_REISERFS_FS_XATTR=y\nCONFIG_REISERFS_FS_POSIX_ACL=y\nCONFIG_REISERFS_FS_SECURITY=y": ${CONFIG_FILE}

    #
    # Enable Tulip network driver support.  This is needed for the "legacy"
    # network adapter provided by Hyper-V
    #
    sed --in-place -e s:"# CONFIG_TULIP is not set":"CONFIG_TULIP=y\nCONFIG_TULIP_MMIO=y": ${CONFIG_FILE}
    
    if [ "${ACTIVATE_GCOV}" == "yes" ];then
        EnableGcov "${CONFIG_FILE}"
    fi
    
    yes "" | make oldconfig
fi
UpdateSummary "make oldconfig: Success"

#
# Build the kernel
#
dbgprint 1 "Building the kernel."
    
if [ $proc_count -eq 1 ]; then
    (time make) >/root/Perf_BuildKernel_make.log 2>&1
else
    (time make -j $proc_count) >/root/Perf_BuildKernel_make.log 2>&1
fi

sts=$?
if [ 0 -ne ${sts} ]; then
    dbgprint 1 "Kernel make failed: ${sts}"
    dbgprint 1 "Aborting test."
    UpdateTestState "TestAborted"
    UpdateSummary "make: Failed"
    exit 110
else
    UpdateSummary "make: Success"
fi

#
# Build the kernel modules
#
dbgprint 1 "Building the kernel modules."
if [ $proc_count -eq 1 ]; then
    (time make modules_install) >/root/Perf_BuildKernel_makemodulesinstall.log 2>&1
else
    (time make modules_install -j $proc_count) >/root/Perf_BuildKernel_makemodulesinstall.log 2>&1
fi

sts=$?
if [ 0 -ne ${sts} ]; then
    dbgprint 1 "Kernel make failed: ${sts}"
    dbgprint 1 "Aborting test."
    UpdateTestState "TestAborted"
    UpdateSummary "make modules_install: Failed"    
    exit 110
else
    UpdateSummary "make modules_install: Success"
fi

#
# Install the kernel
#
dbgprint 1 "Installing the kernel."
if [ $proc_count -eq 1 ]; then
    (time make install) >/root/Perf_BuildKernel_makeinstall.log 2>&1
else
    (time make install -j $proc_count) >/root/Perf_BuildKernel_makeinstall.log 2>&1
fi

sts=$?
if [ 0 -ne ${sts} ]; then
    echo "kernel build failed: ${sts}"
    UpdateTestState "TestAborted"
    UpdateSummary "make install: Failed"
    exit 130
else
    UpdateSummary "make install: Success"
fi

#
# Save the current Kernel version for comparision with the version
# of the new kernel after the reboot.
#
cd ~
dbgprint 3 "Saving version number of current kernel in oldKernelVersion.txt"
uname -r > ~/oldKernelVersion.txt

### Grub Modification ###
# Update grub.conf (we only support v1 right now, grub v2 will have to be added
# later)
grubversion=1
if [ -e /boot/grub/grub.conf ]; then
        grubfile="/boot/grub/grub.conf"
elif [ -e /boot/grub/menu.lst ]; then
        grubfile="/boot/grub/menu.lst"
else
        echo "grub v1 files does not appear to be installed on this system. it should use grub v2."
        # the new kernel is the default one to boot next time
        grubversion=2
fi

if [ 1 -eq ${grubversion} ]; then
    echo "Update grub v1 files."
    new_default_entry_num="0"
    # added
    sed --in-place=.bak -e "s/^default\([[:space:]]\+\|=\)[[:digit:]]\+/default\1$new_default_entry_num/" $grubfile
    # Display grub configuration after our change
    echo "Here are the new contents of the grub configuration file:"
    cat $grubfile
fi

#
# Let the caller know everything worked
#
dbgprint 1 "Exiting with state: TestCompleted."
UpdateTestState "TestCompleted"

exit 0
