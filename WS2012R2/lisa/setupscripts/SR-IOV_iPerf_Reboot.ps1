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

<#
.Synopsis
    While iPerf is transferring data over a SR-IOV connection, reboot the VM.

.Description
    Description:
    While iPerf is transferring data over a SR-IOV connection, reboot the VM.
    Steps:
        1.  Configure a Linux VM with SR-IOV, and a second VM with SR-IOV (Windows or Linux).
        2.  Start iPerf in server mode on the second VM.
        3.  On the Linux VM, start iPerf in client mode for about a 10 minute run.
        4.  While the iPerf client is transferring data, reboot the Linux client VM.
            Note: before reboot - note the TX packets on the VF
        5.  After reboot, check the TX packets - it should drop to 0 & 
            start the iPerf client again.
    Acceptance Criteria:
        After the reboot, the SR-IOV device works correctly.
 
.Parameter vmName
    Name of the test VM.

.Parameter hvServer
    Name of the Hyper-V server hosting the VM.

.Parameter testParams
    Semicolon separated list of test parameters.
    This setup script does not use any setup scripts.

.Example
    <test>
        <testName>iPerf_Reboot</testName>
        <testScript>setupscripts\SR-IOV_iPerf_Reboot.ps1</testScript>
        <files>remote-scripts/ica/utils.sh,remote-scripts/ica/SR-IOV_Utils.sh</files> 
        <setupScript>
            <file>setupscripts\RevertSnapshot.ps1</file>
            <file>setupscripts\SR-IOV_enable.ps1</file>
        </setupScript> 
        <noReboot>False</noReboot>
        <testParams>
            <param>NIC=NetworkAdapter,External,SRIOV,001600112200</param>
            <param>TC_COVERED=SRIOV-9</param>
            <param>VF_IP1=10.11.12.31</param>
            <param>VF_IP2=10.11.12.32</param>
            <param>NETMASK=255.255.255.0</param>
            <param>REMOTE_SERVER=remoteHostName</param>
        </testParams>
        <timeout>1800</timeout>
    </test>
#>

param ([String] $vmName, [String] $hvServer, [string] $testParams)

#############################################################
#
# Main script body
#
#############################################################
$retVal = $False
$leaveTrail = "no"

#
# Check the required input args are present
#

# Write out test Params
$testParams


if ($hvServer -eq $null)
{
    "ERROR: hvServer is null"
    return $False
}

if ($testParams -eq $null)
{
    "ERROR: testParams is null"
    return $False
}

#change working directory to root dir
$testParams -match "RootDir=([^;]+)"
if (-not $?)
{
    "Mandatory param RootDir=Path; not found!"
    return $false
}
$rootDir = $Matches[1]

if (Test-Path $rootDir)
{
    Set-Location -Path $rootDir
    if (-not $?)
    {
        "ERROR: Could not change directory to $rootDir !"
        return $false
    }
    "Changed working directory to $rootDir"
}
else
{
    "ERROR: RootDir = $rootDir is not a valid path"
    return $false
}

# Source TCUitls.ps1 for getipv4 and other functions
if (Test-Path ".\setupScripts\TCUtils.ps1")
{
    . .\setupScripts\TCUtils.ps1
}
else
{
    "ERROR: Could not find setupScripts\TCUtils.ps1"
    return $false
}

# Source NET_UTILS.ps1 for network functions
if (Test-Path ".\setupScripts\NET_UTILS.ps1")
{
    . .\setupScripts\NET_UTILS.ps1
}
else
{
    "ERROR: Could not find setupScripts\NET_Utils.ps1"
    return $false
}

# Process the test params
$params = $testParams.Split(';')
foreach ($p in $params)
{
    $fields = $p.Split("=")
    switch ($fields[0].Trim())
    {
        "SshKey" { $sshKey = $fields[1].Trim() }
        "ipv4" { $ipv4 = $fields[1].Trim() }   
        "VF_IP1" { $vmVF_IP1 = $fields[1].Trim() }
        "VF_IP2" { $vmVF_IP2 = $fields[1].Trim() }
        "NETMASK" { $netmask = $fields[1].Trim() }
        "VM2NAME" { $vm2Name = $fields[1].Trim() }
        "REMOTE_SERVER" { $remoteServer = $fields[1].Trim()}
        "TC_COVERED" { $TC_COVERED = $fields[1].Trim() }
    }
}

$summaryLog = "${vmName}_summary.log"
del $summaryLog -ErrorAction SilentlyContinue
Write-Output "This script covers test case: ${TC_COVERED}" | Tee-Object -Append -file $summaryLog

# Get VM2 ipv4
$vm2ipv4 = GetIPv4 $vm2Name $remoteServer
"${vm2Name} IPADDRESS: ${vm2ipv4}"

#
# Configure eth1 on test VM
#
$retVal = ConfigureVF $ipv4 $sshKey $netmask
if (-not $retVal)
{
    "ERROR: Failed to configure eth1 on vm $vmName (IP: ${ipv4}), by setting a static IP of $vmVF_IP1 , netmask $netmask"
    return $false
}

#
# Install iPerf3 on VM1
#
"Installing iPerf3 on ${vmName}"
$retval = .\bin\plink.exe -i ssh\$sshKey root@${ipv4} "dos2unix SR-IOV_Utils.sh && source SR-IOV_Utils.sh && InstallDependencies"
if (-not $retVal)
{
    "ERROR: Failed to install iPerf3 on vm $vmName (IP: ${ipv4})"
    return $false
}

#
# Run iPerf3 with SR-IOV enabled
#
# Start the client side
"Start Client"
.\bin\plink.exe -i ssh\$sshKey root@${vm2ipv4}  "kill `$(ps aux | grep iperf | head -1 | awk '{print `$2}')"
Start-Sleep -s 5
.\bin\plink.exe -i ssh\$sshKey root@${vm2ipv4}  "iperf3 -s > client.out &"

"Start Server"
# Start iPerf3 testing
Start-Sleep -s 5
.\bin\plink.exe -i ssh\$sshKey root@${ipv4} "echo 'source constants.sh && iperf3 -t 600 -c `$VF_IP2 --logfile PerfResults.log &' > runIperf.sh"
Start-Sleep -s 5
.\bin\plink.exe -i ssh\$sshKey root@${ipv4} "bash ~/runIperf.sh > ~/iPerf.log 2>&1"

# Wait 60 seconds and read the throughput
"Get Logs"
Start-Sleep -s 20
[decimal]$vfBeforeThroughput = .\bin\plink.exe -i ssh\$sshKey root@${ipv4} "tail -2 PerfResults.log | head -1 | awk '{print `$7}'"
if (-not $vfBeforeThroughput){
    "ERROR: No result was logged! Check if iPerf was executed!" | Tee-Object -Append -file $summaryLog
    return $false
}

"The throughput before rebooting VM is $vfBeforeThroughput Gbits/sec" | Tee-Object -Append -file $summaryLog

# Get TX packets from VF
$vfName = .\bin\plink.exe -i ssh\$sshKey root@${ipv4} "ls /sys/class/net | grep -v 'eth0\|eth1\|lo'"
if (-not $vfName) {
    "INFO: Could not extract VF name from VM" | Tee-Object -Append -file $summaryLog
}
[int]$txValue_beforeReboot = .\bin\plink.exe -i ssh\$sshKey root@${ipv4} "ifconfig $vfName | grep 'TX packets' | sed 's/:/ /' | awk '{print `$3}'"
"TX packet count before reboot is $txValue_beforeReboot" | Tee-Object -Append -file $summaryLog
#
# Reboot VM1
#
Restart-VM -VMName $vmName -ComputerName $hvServer -Force
$timeout = 200
if (-not (WaitForVMToStartKVP $vmName $hvServer $timeout ))
{
    Write-Output "Error: ${vmName} failed to restart" | Tee-Object -Append -file $summaryLog
    return $false
}

Start-Sleep -s 5
# Get the ipv4, maybe it may change after the reboot
$ipv4 = GetIPv4 $vmName $hvServer
"${vmName} IP Address after reboot: ${ipv4}"

Start-Sleep -s 60
# Check if VF is still up & running
$vfName = .\bin\plink.exe -i ssh\$sshKey root@${ipv4} "ls /sys/class/net | grep -v 'eth0\|eth1\|lo'"
Start-Sleep -s 10
$status = .\bin\plink.exe -i ssh\$sshKey root@${ipv4} "ifconfig $vfName" 
if (-not $status) {
    "ERROR: The VF $vfName is down after reboot!" | Tee-Object -Append -file $summaryLog
    return $false    
}

[int]$txValue_afterReboot = .\bin\plink.exe -i ssh\$sshKey root@${ipv4} "ifconfig $vfName | grep 'TX packets' | sed 's/:/ /' | awk '{print `$3}'"
if ($txValue_afterReboot -ge $txValue_beforeReboot){
    "ERROR: TX packet count didn't decrease after reboot" | Tee-Object -Append -file $summaryLog
    return $false   
}
else {
    if ($txValue_afterReboot -gt 0){
        "INFO: TX packet count after reboot is $txValue_afterReboot" | Tee-Object -Append -file $summaryLog  
    }
    else {
        "INFO: TX packet count is 0 after reboot" | Tee-Object -Append -file $summaryLog   
    }
}

# Restart iPerf 3 on VM2
.\bin\plink.exe -i ssh\$sshKey root@${vm2ipv4} "kill `$(ps aux | grep iperf | head -1 | awk '{print `$2}')"
.\bin\plink.exe -i ssh\$sshKey root@${vm2ipv4}  "iperf3 -s > client.out &"

# Start iPerf3 again
Start-Sleep -s 5
.\bin\plink.exe -i ssh\$sshKey root@${ipv4} "echo 'source constants.sh && iperf3 -t 600 -c `$VF_IP2 --logfile PerfResults.log &' > runIperf.sh"
Start-Sleep -s 5
.\bin\plink.exe -i ssh\$sshKey root@${ipv4} "bash ~/runIperf.sh > ~/iPerf.log 2>&1"

# Read the throughput again, it should be higher than before
# We should see a a similar throughput as before. If the throughput after reboot
# is lower than 70% of the first recorded throughput, the test is considered failed
Start-Sleep -s 30
[decimal]$vfBeforeThroughput = $vfBeforeThroughput * 0.7
[decimal]$vfFinalThroughput = .\bin\plink.exe -i ssh\$sshKey root@${ipv4} "tail -2 PerfResults.log | head -1 | awk '{print `$7}'"

"The throughput after rebooting the VM is $vfFinalThroughput Gbits/sec" | Tee-Object -Append -file $summaryLog
if ($vfBeforeThroughput -ge $vfFinalThroughput ) {
    "ERROR: After rebooting the VM, the throughput is significantly lower
    Please check if the VF was successfully restarted" | Tee-Object -Append -file $summaryLog
    return $false 
}

return $true