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
    values = ["amzn2-ami-kernel-*-x86_64-gp2"]
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
  vpc_security_group_ids = [aws_security_group.jump_host_sg.id]

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

  tags = {
    Name = "${local.app_name}-jump-host-#{ENV}#"
  }

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

resource "aws_security_group" "jump_host_sg" {
  name        = "${local.app_name}-jump-host-#{ENV}#"
  description = "Security group for jump host"

  vpc_id = module.vpc.vpc_id

      egress {
     description = "Allow all outbound traffic"
     from_port   = 0
     to_port     = 0
     protocol    = "-1"
     cidr_blocks = ["0.0.0.0/0"]
    }
}

//noinspection MissingModule
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name = "${local.app_name}-eks-#{ENV}#"
  cluster_version = "1.25"

  vpc_id = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets


  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"

  }

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 3
      desired_size = 2
    }
  }
}

data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

//noinspection MissingModule
module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.7.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

resource "aws_eks_addon" "ebs-csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.5.2-eksbuild.1"
  service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
  tags = {
    "eks_addon" = "ebs-csi"
    "terraform" = "true"
  }
}