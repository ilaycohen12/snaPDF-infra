# ArgoCD is reachable at https://argocd-{dev,prod}.snapdf.bond (infra #26 —
# shares the environment's one ALB via Nginx, no longer its own LoadBalancer
# Service, so there's no EXTERNAL-IP to copy from kubectl anymore).
