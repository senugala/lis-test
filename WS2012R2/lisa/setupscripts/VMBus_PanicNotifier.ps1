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
    Verify the Hyper-V host logs a 18590 event in the Hyper-V-Worker-Admin
    event log when the Linux guest panics.

.Description
    The Linux kernel allows a driver to register a Panic Notifier handler
    which will be called if the Linux kernel panics.  The hv_vmbus driver
    registers a panic notifier handler.  When this handler is called, it
    will write to the Hyper-V crash MSR registers.  This results in the
    Hyper-V host logging a 18590 event in the Hyper-V-Worker-Admin event
    log.

.Parameter vmName
    Name of the test VM.

.Parameter hvServer
    Name of the server hosting the test VM.

.Parameter testParams
    Test data for this test case

.Example
    setupScripts\VMBus_PanicNotifier.ps1 -vmName "myVm" -hvServer "localhost -TestParams "rootDir=c:\lisa\;TC_COVERED=VMBUS-04;sshKey=demo.ppk;ipv4=192.168.1.101"

.Link
    None.
#>

param( [String] $vmName, [String] $hvServer, [String] $testParams )

$rootDir = $null
$ip = $Null
$ipv4 = "undefined"
$sshKey = "undefined"
$kdump_action = "undefined"

#######################################################################
#
# Main script body
#
#######################################################################

#
# Make sure the required arguments were passed
#
if (-not $vmName)
{
    "Error: no VMName was specified"
    return $False
}

if (-not $hvServer)
{
    "Error: No hvServer was specified"
    return $False
}

if (-not $testParams)
{
    "Error: No test parameters specified"
    return $False
}

#
# Parse the test parameters
#
$params = $testParams.Split(";")
foreach ($p in $params)
{
    $fields = $p.Split("=")
    switch ($fields[0].Trim())
    {
    "ipv4"        { $ipv4      = $fields[1].Trim() }
    "sshkey"      { $sshKey    = $fields[1].Trim() }
    "rootdir"     { $rootDir   = $fields[1].Trim() }
    "onKdump"     { $kdump_action = $fields[1].Trim() }
    "TC_COVERED"  { $tcCovered = $fields[1].Trim() }
    default       {<# Ignore unknown test params #>}
    }
}

if (-not $rootDir)
{
    "Error : no rootdir was specified"
    return $False
}

if (-not (Test-Path -Path $rootDir))
{
    "Error : The rootDir directory '${rootDir}' does not exist"
    return $False
}

if (-not $kdump_action)
{
    "Error : No onKdump parameter specified"
    return $False
}

cd $rootDir

$summaryLog  = "${vmName}_summary.log"
Del $summaryLog -ErrorAction SilentlyContinue
echo "Covers : ${tcCovered}" >> $summaryLog

# Source TCUtils.ps1
if (Test-Path ".\setupScripts\TCUtils.ps1") {
    . .\setupScripts\TCUtils.ps1
} else {
    "Error: Could not find setupScripts\TCUtils.ps1"
}

# if host build number lower than 9600, skip test
$BuildNumber = GetHostBuildNumber $hvServer
if ($BuildNumber -eq 0) {
    return $False
}
elseif ($BuildNumber -lt 9600) {
	"Info: Feature supported only on WS2012R2 and newer"
    return $Skipped
}

#
# Ensure required parameters were specified
#
if ($sshKey -eq "undefined")
{
    "Error: The 'sshkey' test parameter was not specified"
    return $False
}

if (-not (Test-Path -Path "ssh\${sshkey}"))
{
    "Error: The sshkey '${sshkey}' does not exist"
    return $False
}

if ($ipv4 -eq "undefined")
{
    "Error: The 'ipv4' test parameter was not specified"
    return $False
}

#
# Ensure the VM exists and is running
#
$vm = Get-VM -Name $vmName -ComputerName $hvServer
if (-not $vm)
{
    "Error: The test VM '${vmName}' does not exist on server ${hvServer}'"
    return $False
}

if ($vm.State -ne "Running")
{
    "Error: The test VM '${vmName}' is not in a running state"
    return $False
}

$sts = SendCommandToVM $ipv4 $sshKey "service kdump ${kdump_action}"
if (-not $sts) {
    $sts = SendCommandToVM $ipv4 $sshKey "service kdump-tools ${kdump_action}"
    if (-not $sts) {
        Write-Output "Kdump can't be started !" |Tee-Object -Append -file $summaryLog
        return $False
    }
}

Start-Sleep -S 9

# enable the sysrq handle
.\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "sysctl -w kernel.sysrq=1"

#
# Note the current time, then panic the VM
#
"Info : Panic the test VM"
$prePanicTime = [DateTime]::Now

.\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "echo 'echo c > /proc/sysrq-trigger' | at now + 1 minutes"

#
# Give the host a few seconds to record the event
#
Start-Sleep -S 90

#
# Check the event log for the 18590 event from our VM
#
$testPassed = $False

$events = @(Get-WinEvent -FilterHashTable @{LogName = "Microsoft-Windows-Hyper-V-Worker-Admin"; StartTime = $prePanicTime} -ComputerName $hvServer -ErrorAction SilentlyContinue)
foreach ($evt in $events)
{
    if ($evt.id -eq 18590)
    {
        if ($evt.message.Contains("${vmName}"))
        {
            "Info : VM '${vmName}' successfully logged an 18590 event"
            $testPassed = $True
            break
        }
    }
}

if (-not $testPassed)
{
    "Error: Event 18590 was not logged by VM ${vmName}"
    "       Make sure KDump status is ${kdump_action} on the VM"
}

#
# Stop the VM, then restart it
#
Stop-VM -Name $vmName -ComputerName $hvServer -Force -TurnOff

Start-VM -Name $vmName -ComputerName $hvServer
$vm = Get-VM -Name $vmName -ComputerName $hvServer

if ($vm.State -ne "Running")
{
    "Error: The test VM '${vmName}' is not in a running state"
    return $False
}

#
# Wait up to 5 minutes for the VM to come up
#
$timeout = 300

while ($timeout -gt 0)
{
    $ip = GetIPv4 -vmName $vmName -Server $hvServer
    if ($ip -ne $Null)
    {
        break
    }

    Start-Sleep -S 5
    $timeout -= 5
}

if ($timeout -le 0)
{
    "Warn: Unable to start the VM after the panic"
}

#
# Report test results
#
return $testPassed
