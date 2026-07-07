variable "github_pat" {
  description = "GitHub PAT Terraform uses to keep the ArgoCD webhook in sync with the random secret it generates — supplied via TF_VAR_github_pat at apply time, never committed"
  type        = string
  sensitive   = true
}
