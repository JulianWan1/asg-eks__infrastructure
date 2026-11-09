# One-command up/down for the devops-lab project.
#
# Foundation (VPC, RDS, ECR) is shared. You pick ONE compute layer on top.
# Switching: `make down-eks && make up-asg` (or the reverse).
#
# First time in each directory: run `terraform init -upgrade` once.
#   cd foundation && terraform init -upgrade
#   cd eks && terraform init -upgrade
#   cd asg && terraform init -upgrade

APP_DIR := ../url-shortener

.PHONY: up-asg down-asg up-eks down-eks plan-asg plan-eks push-image deploy

# --- shared ----------------------------------------------------------------

push-image:
	@ECR_URL=$$(terraform -chdir=foundation output -raw ecr_repository_url) && \
	aws ecr get-login-password --region ap-southeast-1 \
	  | docker login --username AWS --password-stdin "$$ECR_URL" && \
	docker build --platform linux/amd64 -t "$$ECR_URL:latest" $(APP_DIR) && \
	docker push "$$ECR_URL:latest"

deploy:
	kubectl label namespace default elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite
	kubectl create secret generic app-secrets \
	  --from-literal=DATABASE_URL="$$(terraform -chdir=foundation output -raw database_url)" \
	  --dry-run=client -o yaml | kubectl apply -f -
	@ECR_URL=$$(terraform -chdir=foundation output -raw ecr_repository_url) && \
	sed "s|__ECR_IMAGE__|$$ECR_URL:latest|" eks/k8s/deployment.yaml | kubectl apply -f -
	kubectl apply -f eks/k8s/service.yaml
	kubectl apply -f eks/k8s/ingress.yaml
	kubectl apply -f eks/k8s/hpa.yaml

# --- ASG compute layer (Phase 1) ------------------------------------------

plan-asg:
	terraform -chdir=foundation plan
	terraform -chdir=asg plan

up-asg:
	terraform -chdir=foundation apply -auto-approve
	$(MAKE) push-image
	terraform -chdir=asg apply -auto-approve

down-asg:
	terraform -chdir=asg destroy -auto-approve
	terraform -chdir=foundation destroy -auto-approve

# --- EKS compute layer (Phase 2) ------------------------------------------

plan-eks:
	terraform -chdir=foundation plan
	terraform -chdir=eks plan

up-eks:
	terraform -chdir=foundation apply -auto-approve
	$(MAKE) push-image
	terraform -chdir=eks apply -auto-approve
	aws eks update-kubeconfig \
	  --region ap-southeast-1 \
	  --name $$(terraform -chdir=eks output -raw cluster_name)
	# Install / upgrade AWS Load Balancer Controller
	helm repo add eks https://aws.github.io/eks-charts || true
	helm repo update
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
	  -n kube-system \
	  --set clusterName="$$(terraform -chdir=eks output -raw cluster_name)" \
	  --set serviceAccount.create=true \
	  --set serviceAccount.name=aws-load-balancer-controller \
	  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$$(terraform -chdir=eks output -raw lbc_role_arn)"
	kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s
	# Install / upgrade metrics-server
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ || true
	helm repo update
	helm upgrade --install metrics-server metrics-server/metrics-server \
	  -n kube-system \
	  --set args[0]="--kubelet-insecure-tls"
	kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
	$(MAKE) deploy

down-eks:
	kubectl delete ingress url-shortener --ignore-not-found
	sleep 30
	@VPC_ID=$$(terraform -chdir=foundation output -raw vpc_id 2>/dev/null) && \
	if [ -n "$$VPC_ID" ]; then \
	  echo "Cleaning up LBC security groups in VPC $$VPC_ID..." && \
	  aws ec2 describe-security-groups \
	    --filters "Name=vpc-id,Values=$$VPC_ID" "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
	    --query 'SecurityGroups[*].GroupId' --output text | \
	  tr '\t' '\n' | \
	  while read sg; do \
	    [ -n "$$sg" ] && echo "Deleting SG $$sg" && aws ec2 delete-security-group --group-id "$$sg" || true; \
	  done; \
	fi
	terraform -chdir=eks destroy -auto-approve
	terraform -chdir=foundation destroy -auto-approve