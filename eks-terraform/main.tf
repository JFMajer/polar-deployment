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

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", "eu-north-1"]
  }
}

data "aws_caller_identity" "current" {}
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
  spot_price                          = "0.03"
  spot_wait_for_fulfillment           = true
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

// create policy for jump host to allow all operations on EKS
resource "aws_iam_policy" "jump_host" {
  name = "${local.app_name}-jump-host-eks-policy-#{ENV}#"
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "eks:*"
            ],
            "Effect": "Allow",
            "Resource": "*"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "jump_host" {
  role       = aws_iam_role.jump_host.name
  policy_arn = aws_iam_policy.jump_host.arn
}

resource "aws_iam_role_policy_attachment" "jump_host_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.jump_host.name
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

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
      configuration_values = jsonencode({
        env = {
          # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  cluster_name = "${local.app_name}-eks-#{ENV}#"
  cluster_version = "1.25"

  vpc_id = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets

  manage_aws_auth_configmap = true

  aws_auth_roles = [
    {
      role_arn = aws_iam_role.jump_host.arn
      username = "jump_host"
      groups   = ["system:masters"]
    },
    ]

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
    iam_role_attach_cni_policy = true
  }

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"
      capacity_type = "SPOT"
      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 3
      desired_size = 2
    }
  }

}


//noinspection MissingModule
module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name_prefix      = "VPC-CNI-IRSA"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv6   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

}

resource "aws_security_group_rule" "jump-host-to-eks-control-plane" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = module.eks.eks_cluster_sg_id
  source_security_group_id = aws_security_group.jump_host_sg.id
}

