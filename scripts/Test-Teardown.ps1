<#
.SYNOPSIS
    Verifies that a terraform destroy actually removed everything billable.

.DESCRIPTION
    terraform destroy reports success based on its own state file. That is not
    the same as nothing being left running: resources created outside
    Terraform, resources orphaned by a partial destroy, and resources that
    detach rather than delete will all survive a clean "Destroy complete!".

    This checks AWS directly. Every item below either bills hourly regardless
    of use, or is commonly left behind.

.PARAMETER NamePattern
    Substring matched against resource names and tags, e.g. "ecslab". Filters
    the output to one project. Omit to see everything in the region.

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

$script:Findings = @()

function Write-Check($Name) {
    Write-Host "`n-- $Name" -ForegroundColor Cyan
}

function Report($Category, $Items, $CostNote) {
    if ($Items -and $Items.Count -gt 0) {
        Write-Host "   FOUND $($Items.Count)" -ForegroundColor Yellow
        $Items | ForEach-Object { Write-Host "     $_" }
        if ($CostNote) { Write-Host "     -> $CostNote" -ForegroundColor Yellow }
        $script:Findings += [PSCustomObject]@{
            Category = $Category
            Count    = $Items.Count
            Note     = $CostNote
        }
    }
    else {
        Write-Host "   clear" -ForegroundColor Green
    }
}

function Match-Name($Value) {
    if (-not $NamePattern) { return $true }
    return $Value -like "*$NamePattern*"
}

Write-Host "`nTeardown verification" -ForegroundColor White
Write-Host "Region:  $Region"
Write-Host "Profile: $Profile"
if ($NamePattern) { Write-Host "Filter:  *$NamePattern*" }

try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "Account: $($identity.Account)"
}
catch {
    throw "Could not authenticate with profile '$Profile'."
}

$common = @("--region", $Region, "--profile", $Profile, "--output", "json")

# ---------------------------------------------------------------------------
# The expensive ones. These bill by the hour whether or not anything uses
# them, and are the reason a forgotten lab environment becomes a surprise.
# ---------------------------------------------------------------------------

Write-Check "NAT gateways (~`$32/month each, hourly regardless of traffic)"
$nat = aws ec2 describe-nat-gateways @common --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State,Tags[?Key==`Name`].Value|[0]]' | ConvertFrom-Json
Report "NAT gateway" ($nat | Where-Object { Match-Name $_[2] } | ForEach-Object { "$($_[0])  $($_[1])  $($_[2])" }) "~`$32/month each"

Write-Check "Load balancers (~`$16/month each)"
$lb = aws elbv2 describe-load-balancers @common --query 'LoadBalancers[].[LoadBalancerName,State.Code,Type]' | ConvertFrom-Json
Report "Load balancer" ($lb | Where-Object { Match-Name $_[0] } | ForEach-Object { "$($_[0])  $($_[1])  $($_[2])" }) "~`$16/month each"

Write-Check "Unattached Elastic IPs (~`$3.60/month each)"
# An EIP is free while attached and billed while idle, so a destroy that
# releases the NAT gateway but not its address still costs money.
$eip = aws ec2 describe-addresses @common --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId,Tags[?Key==`Name`].Value|[0]]' | ConvertFrom-Json
Report "Elastic IP" ($eip | Where-Object { Match-Name $_[2] } | ForEach-Object { "$($_[0])  $($_[1])  $($_[2])" }) "~`$3.60/month each — release with: aws ec2 release-address --allocation-id <id>"

Write-Check "Running ECS tasks (Fargate, billed per vCPU-second)"
$clusters = aws ecs list-clusters @common --query 'clusterArns' | ConvertFrom-Json
$runningTasks = @()
foreach ($c in $clusters) {
    $cn = $c.Split('/')[-1]
    if (-not (Match-Name $cn)) { continue }
    $tasks = aws ecs list-tasks --cluster $cn @common --query 'taskArns' | ConvertFrom-Json
    if ($tasks.Count -gt 0) { $runningTasks += "$cn : $($tasks.Count) task(s)" }
}
Report "ECS task" $runningTasks "Fargate bills per vCPU-second while running"

Write-Check "EC2 instances"
$ec2 = aws ec2 describe-instances @common --query 'Reservations[].Instances[?State.Name!=`terminated`].[InstanceId,State.Name,InstanceType,Tags[?Key==`Name`].Value|[0]]' | ConvertFrom-Json
$ec2flat = @($ec2 | ForEach-Object { $_ } | Where-Object { $_ -and (Match-Name $_[3]) } | ForEach-Object { "$($_[0])  $($_[1])  $($_[2])  $($_[3])" })
Report "EC2 instance" $ec2flat "billed hourly while running"

Write-Check "RDS instances and clusters"
$rds = aws rds describe-db-instances @common --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus,DBInstanceClass]' | ConvertFrom-Json
Report "RDS instance" ($rds | Where-Object { Match-Name $_[0] } | ForEach-Object { "$($_[0])  $($_[1])  $($_[2])" }) "billed hourly"

# ---------------------------------------------------------------------------
# Storage. Cheaper, but persists indefinitely and is easy to forget.
# ---------------------------------------------------------------------------

Write-Check "EFS file systems"
$efs = aws efs describe-file-systems @common --query 'FileSystems[].[FileSystemId,Name,SizeInBytes.Value]' | ConvertFrom-Json
Report "EFS" ($efs | Where-Object { Match-Name $_[1] } | ForEach-Object { "$($_[0])  $($_[1])  $($_[2]) bytes" }) "~`$0.30/GB/month"

Write-Check "Unattached EBS volumes"
# A volume detached rather than deleted keeps billing at full rate.
$ebs = aws ec2 describe-volumes @common --query 'Volumes[?State==`available`].[VolumeId,Size,Tags[?Key==`Name`].Value|[0]]' | ConvertFrom-Json
Report "EBS volume" ($ebs | Where-Object { Match-Name $_[2] } | ForEach-Object { "$($_[0])  $($_[1])GiB  $($_[2])" }) "~`$0.08/GB/month"

Write-Check "EBS snapshots"
$snap = aws ec2 describe-snapshots --owner-ids self @common --query 'Snapshots[].[SnapshotId,VolumeSize,Description]' | ConvertFrom-Json
Report "EBS snapshot" ($snap | Where-Object { Match-Name $_[2] } | ForEach-Object { "$($_[0])  $($_[1])GiB" }) "~`$0.05/GB/month"

Write-Check "ECR repositories and image storage"
$ecr = aws ecr describe-repositories @common --query 'repositories[].[repositoryName,repositoryUri]' | ConvertFrom-Json
Report "ECR repository" ($ecr | Where-Object { Match-Name $_[0] } | ForEach-Object { "$($_[0])" }) "~`$0.10/GB/month — usually worth keeping"

# ---------------------------------------------------------------------------
# Free, but worth knowing about. Left-behind VPCs and security groups block a
# later apply that tries to reuse a CIDR or a name.
# ---------------------------------------------------------------------------

Write-Check "VPCs (free, but a leftover blocks CIDR reuse)"
$vpc = aws ec2 describe-vpcs @common --query 'Vpcs[?IsDefault==`false`].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' | ConvertFrom-Json
Report "VPC" ($vpc | Where-Object { Match-Name $_[2] } | ForEach-Object { "$($_[0])  $($_[1])  $($_[2])" }) "free, but blocks CIDR reuse"

Write-Check "CloudWatch log groups (free tier, then ~`$0.03/GB/month)"
$logs = aws logs describe-log-groups @common --query 'logGroups[].[logGroupName,storedBytes,retentionInDays]' | ConvertFrom-Json
Report "Log group" ($logs | Where-Object { Match-Name $_[0] } | ForEach-Object { "$($_[0])  $($_[1]) bytes  retention=$($_[2])" }) "log groups with no retention accumulate indefinitely"

Write-Check "Secrets Manager secrets (~`$0.40/month each)"
# A secret with a recovery window is still billed while pending deletion, and
# blocks recreating one with the same name.
$sec = aws secretsmanager list-secrets @common --query 'SecretList[].[Name,DeletedDate]' | ConvertFrom-Json
Report "Secret" ($sec | Where-Object { Match-Name $_[0] } | ForEach-Object { "$($_[0])$(if ($_[1]) { '  PENDING DELETION' })" }) "~`$0.40/month each"

Write-Check "IAM roles (free, but clutter and name collisions)"
$roles = aws iam list-roles --profile $Profile --output json --query 'Roles[].[RoleName]' | ConvertFrom-Json
Report "IAM role" ($roles | Where-Object { Match-Name $_[0] } | ForEach-Object { "$($_[0])" }) "free"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host "`n$('-' * 70)"
if ($script:Findings.Count -eq 0) {
    Write-Host "Nothing found. Teardown looks complete." -ForegroundColor Green
}
else {
    Write-Host "Remaining resources:" -ForegroundColor Yellow
    $script:Findings | Format-Table -AutoSize
    Write-Host "Some of these may be intentional — an ECR repository holding images," -ForegroundColor DarkGray
    Write-Host "for instance, is usually worth keeping." -ForegroundColor DarkGray
}

Write-Host "`nNote: this checks $Region only. Resources in other regions are invisible here." -ForegroundColor DarkGray
Write-Host "Billing data lags roughly 24 hours, so Cost Explorer will not reflect today.`n" -ForegroundColor DarkGray
