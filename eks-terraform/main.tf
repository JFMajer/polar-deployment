provider "aws" {
  region = "#{AWS_REGION}#"
  assume_role {
    role_arn = "#{AWS_ROLE_TO_ASSUME}#"
  }
  default_tags {
    tags = {
      Environment = "#{ENV}#"
      ManagedBy = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ami-hvm-*-x86_64-gp2"]
  }
}

locals {
  app_name = "polar"
  vpc_cidr = "10.23.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

//noinspection MissingModule
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "4.0.2"

  azs  = local.azs

  enable_nat_gateway = true
  single_nat_gateway = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true

  name = "${local.app_name}-vpc-#{ENV}#"
  cidr = local.vpc_cidr

  private_subnets     = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets      = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]
  database_subnets    = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 8)]
  elasticache_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 12)]

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }

}

//noinspection MissingModule
module "jump_host" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  ami = data.aws_ami.amazon_linux.id
  availability_zone = element(module.vpc.azs, 0)
  subnet_id = element(module.vpc.private_subnets, 0)

  # Spot request specific attributes
  spot_price                          = "0.1"
  spot_wait_for_fulfillment           = true
  spot_type                           = "persistent"
  spot_instance_interruption_behavior = "terminate"
  # End spot request specific attributes

  user_data = file("${path.module}/user_data.sh")
  user_data_replace_on_change = true

  iam_instance_profile = aws_iam_instance_profile.jump_host.name

  cpu_core_count = 1
  cpu_threads_per_core = 1

}

resource "aws_iam_instance_profile" "jump_host" {
  name = "${local.app_name}-jump-host-#{ENV}#"
  role = aws_iam_role.jump_host.name
}

resource "aws_iam_role" "jump_host" {
  name = "${local.app_name}-jump-host-#{ENV}#"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "jump_host" {
  role       = aws_iam_role.jump_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#module "eks" {
#  source  = "terraform-aws-modules/eks/aws"
#  version = "~> 19.0"
#
#  cluster_name = "${local.app_name}-eks-#{ENV}#"
#  cluster_version = "1.25"
#
#  vpc_id = module.vpc.vpc_id
#  subnets = module.vpc.private_subnets
#}