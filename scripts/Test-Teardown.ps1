<#
.SYNOPSIS
    Verifies that a terraform destroy actually removed everything billable.

.DESCRIPTION
    terraform destroy reports success based on its own state file. That is not
    the same as nothing being left running. Resources created outside
    Terraform, orphaned by a partial destroy, or that detach rather than
    delete will all survive a clean "Destroy complete!".

    This queries AWS directly. Every item checked either bills by the hour
    regardless of use, or is commonly left behind.

.PARAMETER NamePattern
    Substring matched against resource names, e.g. "ecslab". Omit to see
    everything in the region.

.EXAMPLE
    .\Test-Teardown.ps1 -NamePattern ecslab -Profile infra
#>

[CmdletBinding()]
param(
    [string]$NamePattern = "",
    [string]$Region = "us-east-1",
    [string]$Profile = "default"
)

$ErrorActionPreference = "Continue"
$Findings = New-Object System.Collections.ArrayList

function Test-NameMatch {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($NamePattern)) { return $true }
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    return $Value -like ('*' + $NamePattern + '*')
}

function Invoke-Check {
    param(
        [string]$Label,
        [string]$Note,
        [string[]]$Items
    )

    Write-Host ''
    Write-Host ('-- ' + $Label) -ForegroundColor Cyan

    if ($Items -and $Items.Count -gt 0) {
        Write-Host ('   FOUND ' + $Items.Count) -ForegroundColor Yellow
        foreach ($i in $Items) { Write-Host ('     ' + $i) }
        if ($Note) { Write-Host ('     -> ' + $Note) -ForegroundColor Yellow }
        $null = $Findings.Add([PSCustomObject]@{
                Resource = $Label
                Count    = $Items.Count
                Note     = $Note
            })
    }
    else {
        Write-Host '   clear' -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Teardown verification' -ForegroundColor White
Write-Host ('Region:  ' + $Region)
Write-Host ('Profile: ' + $Profile)
if ($NamePattern) { Write-Host ('Filter:  *' + $NamePattern + '*') }

try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host ('Account: ' + $identity.Account)
}
catch {
    throw "Could not authenticate with profile '$Profile'."
}

$common = @('--region', $Region, '--profile', $Profile, '--output', 'json')

# --- Hourly billed ---------------------------------------------------------

# NAT gateways bill per hour whether or not traffic flows. Usually the single
# largest line on a lab environment.
$q = 'NatGateways[?State!=`deleted`].[NatGatewayId,State,Tags[?Key==`Name`].Value|[0]]'
$rows = aws ec2 describe-nat-gateways @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[2]) { $items += ($r[0] + '  ' + $r[1] + '  ' + $r[2]) }
}
Invoke-Check -Label 'NAT gateway' -Note 'about USD 32/month each' -Items $items

$q = 'LoadBalancers[].[LoadBalancerName,State.Code,Type]'
$rows = aws elbv2 describe-load-balancers @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[0]) { $items += ($r[0] + '  ' + $r[1] + '  ' + $r[2]) }
}
Invoke-Check -Label 'Load balancer' -Note 'about USD 16/month each' -Items $items

# An Elastic IP is free while attached and billed while idle, so a destroy
# that removes the NAT gateway but not its address still costs money.
$q = 'Addresses[?AssociationId==null].[PublicIp,AllocationId,Tags[?Key==`Name`].Value|[0]]'
$rows = aws ec2 describe-addresses @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[2]) { $items += ($r[0] + '  ' + $r[1] + '  ' + $r[2]) }
}
Invoke-Check -Label 'Unattached Elastic IP' -Note 'about USD 3.60/month each. Release with: aws ec2 release-address --allocation-id ID' -Items $items

$rows = aws ecs list-clusters @common --query 'clusterArns' | ConvertFrom-Json
$items = @()
foreach ($c in $rows) {
    $name = $c.Split('/')[-1]
    if (-not (Test-NameMatch $name)) { continue }
    $tasks = aws ecs list-tasks --cluster $name @common --query 'taskArns' | ConvertFrom-Json
    if ($tasks.Count -gt 0) { $items += ($name + ' : ' + $tasks.Count + ' task(s)') }
}
Invoke-Check -Label 'Running ECS task' -Note 'Fargate bills per vCPU-second while running' -Items $items

$q = 'Reservations[].Instances[?State.Name!=`terminated`].[InstanceId,State.Name,InstanceType,Tags[?Key==`Name`].Value|[0]]'
$rows = aws ec2 describe-instances @common --query $q | ConvertFrom-Json
$items = @()
foreach ($group in $rows) {
    foreach ($r in $group) {
        if (Test-NameMatch $r[3]) { $items += ($r[0] + '  ' + $r[1] + '  ' + $r[2] + '  ' + $r[3]) }
    }
}
Invoke-Check -Label 'EC2 instance' -Note 'billed hourly while running' -Items $items

$q = 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus,DBInstanceClass]'
$rows = aws rds describe-db-instances @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[0]) { $items += ($r[0] + '  ' + $r[1] + '  ' + $r[2]) }
}
Invoke-Check -Label 'RDS instance' -Note 'billed hourly' -Items $items

# --- Storage ---------------------------------------------------------------

$q = 'FileSystems[].[FileSystemId,Name,SizeInBytes.Value]'
$rows = aws efs describe-file-systems @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[1]) { $items += ($r[0] + '  ' + $r[1] + '  ' + $r[2] + ' bytes') }
}
Invoke-Check -Label 'EFS file system' -Note 'about USD 0.30/GB/month' -Items $items

# A volume detached rather than deleted keeps billing at the full rate.
$q = 'Volumes[?State==`available`].[VolumeId,Size,Tags[?Key==`Name`].Value|[0]]'
$rows = aws ec2 describe-volumes @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[2]) { $items += ($r[0] + '  ' + $r[1] + ' GiB  ' + $r[2]) }
}
Invoke-Check -Label 'Unattached EBS volume' -Note 'about USD 0.08/GB/month' -Items $items

$q = 'Snapshots[].[SnapshotId,VolumeSize,Description]'
$rows = aws ec2 describe-snapshots --owner-ids self @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[2]) { $items += ($r[0] + '  ' + $r[1] + ' GiB') }
}
Invoke-Check -Label 'EBS snapshot' -Note 'about USD 0.05/GB/month' -Items $items

$q = 'repositories[].[repositoryName]'
$rows = aws ecr describe-repositories @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[0]) { $items += $r[0] }
}
Invoke-Check -Label 'ECR repository' -Note 'about USD 0.10/GB/month. Often intentional' -Items $items

# --- Free, but obstructive -------------------------------------------------

# A leftover VPC blocks reusing its CIDR on the next apply.
$q = 'Vpcs[?IsDefault==`false`].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]'
$rows = aws ec2 describe-vpcs @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[2]) { $items += ($r[0] + '  ' + $r[1] + '  ' + $r[2]) }
}
Invoke-Check -Label 'VPC' -Note 'free, but blocks CIDR reuse' -Items $items

$q = 'logGroups[].[logGroupName,storedBytes,retentionInDays]'
$rows = aws logs describe-log-groups @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[0]) { $items += ($r[0] + '  ' + $r[1] + ' bytes  retention=' + $r[2]) }
}
Invoke-Check -Label 'CloudWatch log group' -Note 'groups with no retention accumulate indefinitely' -Items $items

# A secret pending deletion is still billed, and blocks recreating one with
# the same name.
$q = 'SecretList[].[Name,DeletedDate]'
$rows = aws secretsmanager list-secrets @common --query $q | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (-not (Test-NameMatch $r[0])) { continue }
    $line = $r[0]
    if ($r[1]) { $line = $line + '  PENDING DELETION' }
    $items += $line
}
Invoke-Check -Label 'Secrets Manager secret' -Note 'about USD 0.40/month each' -Items $items

$rows = aws iam list-roles --profile $Profile --output json --query 'Roles[].[RoleName]' | ConvertFrom-Json
$items = @()
foreach ($r in $rows) {
    if (Test-NameMatch $r[0]) { $items += $r[0] }
}
Invoke-Check -Label 'IAM role' -Note 'free' -Items $items

# --- Summary ---------------------------------------------------------------

Write-Host ''
Write-Host ('-' * 70)

if ($Findings.Count -eq 0) {
    Write-Host 'Nothing found. Teardown looks complete.' -ForegroundColor Green
}
else {
    Write-Host 'Remaining resources:' -ForegroundColor Yellow
    $Findings | Format-Table -AutoSize
    Write-Host 'Some may be intentional. An ECR repository holding images, for' -ForegroundColor DarkGray
    Write-Host 'instance, is usually worth keeping.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host ('This checks ' + $Region + ' only. Other regions are invisible here.') -ForegroundColor DarkGray
Write-Host 'Billing data lags about 24 hours, so Cost Explorer will not show today.' -ForegroundColor DarkGray
Write-Host ''
