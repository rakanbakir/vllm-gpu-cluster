# ============================================================================
# Variables
# ============================================================================

variable "region" {
  type        = string
  description = "AWS region for all resources (UAE: me-central-1 for data residency)"
  default     = "me-central-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, production)"
  default     = "production"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
  default     = "mal-vllm-cluster"
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version for EKS cluster"
  default     = "1.31"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones for subnets (must be in the selected region)"
  default     = ["me-central-1a", "me-central-1b"]
}

variable "private_subnets" {
  type        = list(string)
  description = "CIDR blocks for private subnets (GPU nodes)"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnets" {
  type        = list(string)
  description = "CIDR blocks for public subnets (load balancers)"
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# GPU Node Group Configuration

variable "gpu_instance_type" {
  type        = string
  description = "EC2 instance type for GPU node group (g4dn.xlarge: 1x T4 GPU, 4 vCPU, 16 GiB)"
  default     = "g4dn.xlarge"
}

variable "gpu_desired_size" {
  type        = number
  description = "Desired number of GPU worker nodes"
  default     = 1
}

variable "gpu_min_size" {
  type        = number
  description = "Minimum number of GPU worker nodes"
  default     = 1
}

variable "gpu_max_size" {
  type        = number
  description = "Maximum number of GPU worker nodes"
  default     = 5
}

variable "gpu_spot_enabled" {
  type        = bool
  description = "Use spot instances for GPU nodes to reduce cost (~60-70% savings)"
  default     = true
}

variable "gpu_spot_fallback_on_demand" {
  type        = bool
  description = "Fallback to on-demand if spot capacity is unavailable"
  default     = true
}

# ECR Repository

variable "ecr_repository_name" {
  type        = string
  description = "Name of the ECR repository for the vLLM Docker image"
  default     = "mal-vllm-opt125m"
}

variable "ecr_image_tag_mutability" {
  type        = string
  description = "Image tag mutability setting for ECR"
  default     = "IMMUTABLE"
}

variable "ecr_max_image_count" {
  type        = number
  description = "Maximum number of images to retain in ECR lifecycle policy"
  default     = 20
}

variable "huggingface_token" {
  type        = string
  description = "HuggingFace API token for downloading model weights. Set via TF_VAR_huggingface_token env var."
  sensitive   = true
}
