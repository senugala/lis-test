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
    This script tests VSS backup functionality.

.Description
    This script will backup vm when vm has mounted one partition to different paths.

    Note: The script has to be run on the host. A second partition
    different from the Hyper-V one has to be available.

    A typical xml entry looks like this:

    <test>
        <testName>STOR_VSS_BackupRestore_Mount_Multi_Paths</testName>
        <setupScript>
            <file>setupscripts\RevertSnapshot.ps1</file>
            <file>setupscripts\AddHardDisk.ps1</file>
        </setupScript>
        <files>remote-scripts/ica/utils.sh</files>
        <testScript>setupscripts\STOR_VSS_BackupRestore_Mount_Multi_Paths.ps1</testScript>
        <testParams>
            <param>TC_COVERED=VSS-19</param>
            <param>IDE=0,1,Dynamic</param>
            <param>FILESYS=ext3</param>
        </testParams>
        <timeout>3000</timeout>
        <OnError>Continue</OnError>
    </test>

.Parameter vmName
    Name of the VM to backup/restore.

.Parameter hvServer
    Name of the Hyper-V server hosting the VM.

.Parameter testParams
    Test data for this test case

.Example
    setupScripts\STOR_VSS_Disk_Mount_Multi_Paths.ps1 -hvServer localhost -vmName NameOfVm -testParams 'sshKey=path/to/ssh;rootdir=path/to/testdir;ipv4=ipaddress;driveletter=D:;

#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

$remoteScript = "STOR_VSS_Disk_Mount_Multi_Paths.sh"

$retVal = $false

#######################################################################
#
# Main script body
#
#######################################################################

# Check input arguments
if ($vmName -eq $null)
{
    Write-Output "ERROR: VM name is null"
    return $retVal
}

# Check input params
$params = $testParams.Split(";")

foreach ($p in $params)
{
    $fields = $p.Split("=")
        switch ($fields[0].Trim())
        {
		"TC_COVERED" { $TC_COVERED = $fields[1].Trim() }
        "sshKey" { $sshKey = $fields[1].Trim() }
        "ipv4" { $ipv4 = $fields[1].Trim() }
        "rootdir" { $rootDir = $fields[1].Trim() }
        "driveletter" { $driveletter = $fields[1].Trim() }
        "TestLogDir" { $TestLogDir = $fields[1].Trim() }
        "FILESYS" { $FILESYS = $fields[1].Trim() }
        default  {}
        }
}

if ($null -eq $sshKey)
{
    Write-Output "ERROR: Test parameter sshKey was not specified"
    return $False
}

if ($null -eq $ipv4)
{
    Write-Output "ERROR: Test parameter ipv4 was not specified"
    return $False
}

if ($null -eq $rootdir)
{
    Write-Output "ERROR: Test parameter rootdir was not specified"
    return $False
}

if ($null -eq $driveletter)
{
    Write-Output "ERROR: Test parameter driveletter was not specified."
    return $False
}

if ($null -eq $FILESYS)
{
    Write-Output "ERROR: Test parameter FILESYS was not specified."
    return $False
}

if ($null -eq $TestLogDir)
{
    $TestLogDir = $rootdir
}

# Change the working directory to where we need to be
cd $rootDir

# Source TCUtils.ps1 for common functions
if (Test-Path ".\setupScripts\TCUtils.ps1") {
	. .\setupScripts\TCUtils.ps1
	"Info: Sourced TCUtils.ps1"
}
else {
	"Error: Could not find setupScripts\TCUtils.ps1"
	return $false
}

$loggerManager = [LoggerManager]::GetLoggerManager($vmName, $testParams)
$global:logger = $loggerManager.TestCase

$logger.info("This script covers test case: ${TC_COVERED}")

# Source STOR_VSS_Utils.ps1 for common VSS functions
if (Test-Path ".\setupScripts\STOR_VSS_Utils.ps1") {
	. .\setupScripts\STOR_VSS_Utils.ps1
	$logger.info("Sourced STOR_VSS_Utils.ps1")
}
else {
	$logger.errror("Could not find setupScripts\STOR_VSS_Utils.ps1")
	return $false
}

$sts = runSetup $vmName $hvServer $driveletter
if (-not $sts[-1])
{
    return $False
}

# Run the remote script
$sts = RunRemoteScript $remoteScript
if (-not $sts[-1])
{
    $logger.error("Executing $remoteScript on VM. Exiting test case!")
    return $False
}
$logger.info("$remoteScript execution on VM: Success")


$sts = startBackup $vmName $driveletter
if (-not $sts[-1])
{
    return $False
}
else
{
    $backupLocation = $sts
}

$sts = restoreBackup $backupLocation
if (-not $sts[-1])
{
    return $False
}

$sts = checkResults $vmName $hvServer
if (-not $sts[-1])
{
    $retVal = $False
}
else
{
	$retVal = $True
    $results = $sts
}


runCleanup $backupLocation

$logger.info("Test ${results}")
return $retVal
