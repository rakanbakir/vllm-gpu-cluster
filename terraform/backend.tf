# ============================================================================
# Terraform Backend — Local (default for development/validation)
# ============================================================================
# For production, copy backend.s3.tf.example → backend.tf and fill in values.
# ============================================================================

terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
