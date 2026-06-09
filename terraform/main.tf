# ============================================================================
# Main: VPC, EKS Cluster, GPU Node Group, ECR, Secrets Manager
# ============================================================================

# --- VPC Module ---

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "mal-vllm-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_flow_log                                 = true
  flow_log_destination_type                       = "cloud-watch-logs"
  create_flow_log_cloudwatch_log_group            = true
  flow_log_cloudwatch_log_group_retention_in_days = 30

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# --- Security Group for GPU Nodes ---

resource "aws_security_group" "gpu_nodes" {
  name        = "mal-vllm-gpu-nodes"
  description = "Security group for GPU worker nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow vLLM API from ALB"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Allow Prometheus metrics scraping"
    from_port   = 9400
    to_port     = 9400
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound (HuggingFace model download, ECR pull)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                        = "mal-vllm-gpu-nodes"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "elbv2.k8s.aws/cluster"                     = var.cluster_name
  }
}

# --- EKS Cluster ---

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

  enable_irsa = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_security_group_additional_rules = {
    ingress_nodes_ephemeral_ports = {
      description                = "Node to control plane on ephemeral ports"
      protocol                   = "tcp"
      from_port                  = 1025
      to_port                    = 65535
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  eks_managed_node_groups = {
    gpu-group = {
      name        = "gpu-node-group"
      description = "GPU worker nodes for vLLM inference (g4dn.xlarge with T4 GPU)"

      ami_type       = "AL2_x86_64_GPU"
      instance_types = [var.gpu_instance_type]

      capacity_type = var.gpu_spot_enabled ? "SPOT" : "ON_DEMAND"

      min_size     = var.gpu_min_size
      max_size     = var.gpu_max_size
      desired_size = var.gpu_desired_size

      subnet_ids = module.vpc.private_subnets

      enable_monitoring = true

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      labels = {
        "nvidia.com/gpu"         = "true"
        "node.kubernetes.io/gpu" = "t4"
      }

      taints = [
        {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      ]

      iam_role_additional_policies = {
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      tags = {
        Name         = "mal-vllm-gpu-node"
        GPUModel     = "T4"
        SpotInstance = tostring(var.gpu_spot_enabled)
      }
    }
  }

  tags = {
    Environment = var.environment
    Project     = "mal-vllm-inference"
  }
}

# --- NVIDIA Device Plugin (DaemonSet via Helm) ---

resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  namespace        = "kube-system"
  create_namespace = false
  version          = "0.14.5"

  set {
    name  = "nodeSelector.nvidia\\.com/gpu"
    value = "true"
  }

  depends_on = [module.eks]
}

# --- AWS Load Balancer Controller ---

resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
    }
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.2"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [
    module.eks,
    kubernetes_service_account.alb_controller
  ]
}

# --- ECR Repository ---

resource "aws_ecr_repository" "vllm" {
  name                 = var.ecr_repository_name
  image_tag_mutability = var.ecr_image_tag_mutability

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  force_delete = false

  tags = {
    Name = "mal-vllm-opt125m"
  }
}

resource "aws_ecr_lifecycle_policy" "vllm" {
  repository = aws_ecr_repository.vllm.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain only the last N images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# --- AWS Secrets Manager: HuggingFace Token ---

resource "aws_secretsmanager_secret" "hf_token" {
  name        = "mal-vllm-huggingface-token"
  description = "HuggingFace API token for downloading the opt-125m model"

  recovery_window_in_days = 7

  tags = {
    Name = "mal-vllm-huggingface-token"
  }
}

resource "aws_secretsmanager_secret_version" "hf_token" {
  secret_id = aws_secretsmanager_secret.hf_token.id
  secret_string = jsonencode({
    HF_TOKEN = var.huggingface_token
  })
}

# --- CloudWatch Log Group for VPC Flow Logs ---

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/mal-vllm-flow-logs"
  retention_in_days = 30
  tags = {
    Name = "mal-vllm-vpc-flow-logs"
  }
}

# --- CloudWatch Log Group for EKS Cluster Logging ---

resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
  tags = {
    Name = "mal-vllm-eks-cluster-logs"
  }
}
