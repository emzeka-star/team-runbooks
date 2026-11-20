Purpose and scope
This runbook deploys a fixed number of standalone EC2 instances (default 2) into one Availability Zone using the ec2-instance module from platform-templates (v1.2.0). Access is through SSM Session Manager, not SSH from the internet.
Deliberately excluded, so no Auto Scaling group, launch template or scaling policy; no load balancer or target group; and no spread across AZs. If an instance fails it is not replaced automatically, and an AZ outage takes all instances down. Use this for labs, test boxes and tooling hosts, not production services.
Prerequisites
•	Terraform 1.5 or later, AWS CLI v2, Git, and the Session Manager plugin for the AWS CLI on the workstation.
•	AWS lab account 288743750008 (us-east-1), CLI profile infra. Set it in every PowerShell session: $env:AWS_PROFILE = "infra".
•	platform-templates cloned to C:\dev\platform-templates, and the root config folder at C:\dev\ec2-lab. Never use OneDrive-synced paths.
•	Remote state bucket emzeka-terraform-state-2026, one state key per environment.
•	The account still has its default VPC in us-east-1. If not, replace the VPC and subnet lookups in Step 2 with your own.
What gets created
A deployment with the defaults creates 6 resources. The default VPC and subnet are only looked up, never modified.
Resource	Name	Notes
aws_instance × 2	ec2-lab-1, ec2-lab-2	t3.micro, latest AL2023, IMDSv2 required, encrypted 20 GB gp3 root volume
aws_security_group	ec2-lab-ec2-sg	No inbound by default, all outbound
aws_iam_role	ec2-lab-ec2-role	Trusted by ec2.amazonaws.com
aws_iam_role_policy_attachment	—	AmazonSSMManagedInstanceCore
aws_iam_instance_profile	ec2-lab-ec2-profile	Attached to both instances
Step 1: Confirm the module is published
The module lives at modules/ec2-instance in platform-templates and is tagged v1.2.0. It uses plain aws_instance resources with count, so there is no ASG or load balancer to switch off. Check the tag exists before deploying:
cd C:\dev\platform-templates
git fetch --tags
git tag --list "v1.2*"
If the tag is missing, add the module, then commit, tag and push:
git add modules/ec2-instance
git commit -m "Add ec2-instance module (standalone instances, no ASG/LB)"
git tag v1.2.0
git push origin main --tags
Module inputs:
Input	Default	Purpose
name	required	Prefix for every resource name
instance_count	2	Number of instances
instance_type	t3.micro	Instance size
ami_id	null	Null means latest Amazon Linux 2023 x86_64
vpc_id	required	VPC for the security group
subnet_ids	required	Instances go round-robin across these; pass one subnet for a single AZ
associate_public_ip	true	Public IP, needed for SSM in a default VPC with no endpoints
ingress_rules	[]	Inbound rules; empty means SSM only
key_name	null	Optional key pair; not needed with SSM
root_volume_size	20	Root volume in GB
user_data	null	Optional bootstrap script
tags	{}	Extra tags
Step 2: Write the root config pinned to one AZ
Single AZ comes from passing exactly one subnet. The module spreads instances round-robin across whatever subnets it gets, so a list of all default subnets would put them in different AZs. Create these four files in C:\dev\ec2-lab.
backend.tf (use a different key per environment):
terraform {
  backend "s3" {
    bucket = "emzeka-terraform-state-2026"
    key    = "ec2-lab/terraform.tfstate"
    region = "us-east-1"
  }
}
providers.tf:
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project   = "ec2-lab"
      ManagedBy = "terraform"
    }
  }
}
main.tf:
locals {
  availability_zone = "us-east-1a" # the single AZ for all instances
}

data "aws_vpc" "default" {
  default = true
}

# The default subnet in the chosen AZ only
data "aws_subnet" "single" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = local.availability_zone
  default_for_az    = true
}

module "ec2" {
  # Literal string, pinned to a tag
  source = "git::https://github.com/emzeka-star/platform-templates.git//modules/ec2-instance?ref=v1.2.0"

  name           = "ec2-lab"
  instance_count = 2
  instance_type  = "t3.micro"
  vpc_id         = data.aws_vpc.default.id
  subnet_ids     = [data.aws_subnet.single.id] # one subnet = one AZ

  # SSH between instances only (e.g. Ansible). Remove for SSM-only access.
  ingress_rules = [{
    description = "SSH within VPC (Ansible)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }]
}
outputs.tf:
output "instance_ids" {
  value = module.ec2.instance_ids
}

output "private_ips" {
  value = module.ec2.private_ips
}

output "public_ips" {
  value = module.ec2.public_ips
}
The source line must stay a literal string; Terraform rejects variables or locals there.
Step 3: Deploy
A first apply should report 6 to add, 0 to change, 0 to destroy. Anything else means the folder or state key is wrong, so stop and check.
cd C:\dev\ec2-lab
$env:AWS_PROFILE = "infra"
terraform init
terraform plan
terraform apply
terraform output
Before applying, confirm main.tf is the EC2 config above and the backend key is ec2-lab/terraform.tfstate. Applying a different config against this state key would destroy the instances it tracks.
Step 4: Verify and connect
Both instances should show running in the same AZ and Online in SSM within about 5 minutes of launch.
aws ec2 describe-instances --filters "Name=tag:Project,Values=ec2-lab" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,PrivateIpAddress,State.Name]" --output table --no-cli-pager
aws ssm describe-instance-information --query "InstanceInformationList[].[InstanceId,PingStatus]" --output table --no-cli-pager
aws ssm start-session --target <instance-id>
The session opens as ssm-user in plain sh, with passwordless sudo. Type bash first so ~/.bashrc loads, or exit to leave.
Optional: Ansible server and client
Instance 1 becomes the Ansible server and instance 2 the managed client, over SSH inside the VPC. This setup lives only on the instances and is lost on destroy.
1.	On the server, install Ansible and create its SSH key:
bash
sudo dnf install -y python3-pip git
python3 -m pip install --user ansible
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
2.	On the client, authorize that key for ec2-user (replace the placeholder with the full single line):
sudo mkdir -p /home/ec2-user/.ssh
echo "<ssh-ed25519 line from the server>" | sudo tee /home/ec2-user/.ssh/authorized_keys
sudo chown -R ec2-user:ec2-user /home/ec2-user/.ssh
sudo chmod 700 /home/ec2-user/.ssh
sudo chmod 600 /home/ec2-user/.ssh/authorized_keys
3.	On the server, test SSH, then build the inventory. The al2023 group matches the update-al2023.yml playbook:
ssh ec2-user@<client-private-ip> hostname
mkdir -p ~/ansible
cat > ~/ansible/inventory.ini <<'EOF'
[clients]
client1 ansible_host=<client-private-ip> ansible_user=ec2-user ansible_python_interpreter=/usr/bin/python3

[al2023:children]
clients
EOF
ansible -i ~/ansible/inventory.ini clients -m ping
4.	To run playbooks from emzeka-star/team-runbooks, add a read-only deploy key on the server and clone:
ssh-keygen -t ed25519 -f ~/.ssh/github_deploy -N ""
cat ~/.ssh/github_deploy.pub   # add in GitHub: repo Settings > Deploy keys, write access off
printf 'Host github.com\n  IdentityFile ~/.ssh/github_deploy\n  IdentitiesOnly yes\n' >> ~/.ssh/config
chmod 600 ~/.ssh/config
ssh -T git@github.com
git clone git@github.com:emzeka-star/team-runbooks.git
cd ~/team-runbooks/scripts
ansible-playbook -i ~/ansible/inventory.ini update-al2023.yml --check --diff
ansible-playbook -i ~/ansible/inventory.ini update-al2023.yml
Troubleshooting
Each row below is an issue hit during the November 2026 lab build.
Symptom	Cause	Fix
ssh to a 172.31.x.x address times out from the workstation	Private IPs are only reachable inside the VPC	Run ssh from inside an SSM session on the server
ssh times out from the server	Security group source is wrong, e.g. the client's own /32	Source must be the VPC CIDR or the server's IP; check with aws ec2 describe-security-groups --filters "Name=group-name,Values=ec2-lab-ec2-sg" --no-cli-pager
Permission denied (publickey)	Key missing, broken across lines, or wrong owner or mode on the client	Rewrite authorized_keys with tee (no -a), then chown and chmod; read sudo journalctl -u sshd -n 20 on the client
ansible-playbook: command not found	SSM starts plain sh, which skips ~/.bashrc	Type bash, or export PATH=$PATH:$HOME/.local/bin
Playbook matches no hosts	Its hosts: group (e.g. al2023) is not in the inventory	Add [al2023:children] containing your group
terraform plan shows destroys you did not expect	main.tf was overwritten with another project's config	Restore the EC2 config; never apply until the plan matches
terraform plan says no changes but the live security group differs	Console edits drifting from config	Make the fix in Terraform; if fixed in the console, match the config exactly and re-plan
AWS CLI output stops at -- More --	CLI pager	Press q; add --no-cli-pager
Teardown
The destroy plan should show 0 to add, 0 to change, 6 to destroy, matching the resources table above. Stop if it lists anything else.
cd C:\dev\ec2-lab
$env:AWS_PROFILE = "infra"
terraform plan -destroy
terraform destroy
aws ec2 describe-instances --filters "Name=tag:Project,Values=ec2-lab" --query "Reservations[].Instances[].[InstanceId,State.Name]" --output table --no-cli-pager
Instances show terminated for about an hour before disappearing. Outside Terraform:
•	☐ Delete the server's deploy key in emzeka-star/team-runbooks under Settings > Deploy keys.
•	☐ Keep C:\dev\ec2-lab and the v1.2.0 module; terraform apply rebuilds the instances, but the Ansible setup must be redone.
