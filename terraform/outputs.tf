# ============================================================================
# Outputs
# ============================================================================

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = module.eks.cluster_security_group_id
}

output "cluster_oidc_provider_arn" {
  description = "EKS cluster OIDC provider ARN (for IRSA)"
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (GPU nodes)"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs (load balancers)"
  value       = module.vpc.public_subnets
}

output "ecr_repository_url" {
  description = "ECR repository URL for the vLLM Docker image"
  value       = aws_ecr_repository.vllm.repository_url
}

output "ecr_repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.vllm.name
}

output "secrets_manager_arn" {
  description = "AWS Secrets Manager ARN for HuggingFace token"
  value       = aws_secretsmanager_secret.hf_token.arn
}

output "gpu_node_group_name" {
  description = "GPU node group name"
  value       = module.eks.eks_managed_node_groups["gpu-group"].node_group_name
}

output "kubeconfig_command" {
  description = "Command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name}"
}

output "grafana_admin_password_command" {
  description = "Command to retrieve Grafana admin password"
  value       = "kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
}
