# Kind
KIND_NAME := shipper
KUBE_TEMPLATE := kubectl create --dry-run=client -o yaml

# Handy
OKBLUE := '\033[94m'
OKCYAN := '\033[96m'
OKGREEN := '\033[92m'
WARNING := '\033[93m'
FAIL := '\033[91m'
ENDC := '\033[0m'
BOLD := '\033[1m'

#===========================================

.DEFAULT: all
.PHONY: kind

##############################################
###   ___  ___     _        _ _    ______
###   |  \/  |    | |      | | |   | ___ \.
###   | .  . | ___| |_ __ _| | |   | |_/ /
###   | |\/| |/ _ \ __/ _` | | |   | ___ \.
###   | |  | |  __/ |_ (_| | | |____ |_/ /
###   \_|  |_/\___|\__\__,_|_\_____\____/
###

METALLB := kind/metallb
METALLB_CONFIGMAP := $(METALLB)/configmap.yaml

$(METALLB)/secret.yaml:
	mkdir -p $$(dirname $@)
	$(KUBE_TEMPLATE) secret generic -n metallb-system memberlist \
		--from-literal=secretkey="$$(openssl rand -base64 128)" > $@

deploy-metallb: kind/metallb/secret.yaml
	# Give ArgoCD a loadbalancer endpoint.
	kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}' || true

	# Make a backup
	[ -f $(METALLB_CONFIGMAP).bak ] || cp $(METALLB_CONFIGMAP) $(METALLB_CONFIGMAP).bak

	# Fix the IP Range of MetalLB
	@printf $(WARNING)
	@printf $(BOLD)
	@echo "Setting the MetalLb address range using your docker network"
	@echo "The old file will be copied to $(METALLB_CONFIGMAP).bak"
	@printf $(ENDC)
	@CIDR=$$(docker network inspect -f '{{.IPAM.Config}}' kind | sed 's~\[{\([0-9/.]*\) .*~\1~'); \
	SUBCLASS=$$(echo $$CIDR | awk -F '.' '{printf("%d.%d",$$1,$$2)}'); \
	METALLB_RANGE=$$(grep '\([0-9][0-9\.]*\)-\([0-9][0-9\.]*\)' $(METALLB_CONFIGMAP)); \
	METALLB_CLASS=$$(echo $$METALLB_RANGE | sed 's/^ *- *//' | awk -F '.' '{printf("%d.%d", $$1, $$2) }'); \
	sed -i "s/$$METALLB_CLASS/$$SUBCLASS/g" $(METALLB_CONFIGMAP)

	kustomize build $(METALLB) | kubectl apply -f -


##############################################
###
###          d8888   888       888
###         d88888   888       888
###        d88P888   888       888
###       d88P 888   888       888
###      d88P  888   888       888
###     d88P   888   888       888
###    d8888888888   888       888
###   d88P     888   88888888  88888888
###
###


define METRICS_SERVER_PATCH
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "metrics-server",
            "args": [
              "--cert-dir=/tmp",
              "--secure-port=4443",
              "--kubelet-insecure-tls",
              "--kubelet-preferred-address-types=InternalIP"
            ]
          }
        ]
      }
    }
  }
}
endef
METRICS_SERVER_PATCH := $(shell echo '$(METRICS_SERVER_PATCH)' | jq -c)

clean: delete
	rm -rf $(DISTRIBUTION)

delete:
	kind delete clusters $(KIND_NAME)

kind:
	kind create cluster --name $(KIND_NAME) --config kind/kind-cluster.yaml
	kubectl cluster-info --context kind-$(KIND_NAME)
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.3.6/components.yaml
	# kubectl patch deployment metrics-server -n kube-system -p '$(METRICS_SERVER_PATCH)'
	kubectl create namespace dashboards

docker-secret:
	if ! kubectl get secret push-secret -n dashboards > /dev/null 2>&1; then \
		REGISTRY_SERVER=https://index.docker.io/v1/ ;\
		read -p 'Dockerhub Email: ' EMAIL; \
		read -p 'Dockerhub Username: ' REGISTRY_USER; \
		printf 'Dockerhub Password: '; \
		stty -echo; \
		read REGISTRY_PASSWORD ; \
		stty echo; \
		echo; \
		kubectl create secret docker-registry push-secret -n dashboards \
			--docker-server=$$REGISTRY_SERVER \
			--docker-username=$$REGISTRY_USER \
			--docker-password=$$REGISTRY_PASSWORD  \
			--docker-email=$$EMAIL ; \
	fi

### Local git server,
### For private ArgoCD in kind
gitserver: applications
	docker build . -t gitserver:latest -f kind/gitserver.Dockerfile
	kind load docker-image gitserver:latest --name $(KIND_NAME)

	kubectl create namespace git || true
	kubectl apply -f kind/gitserver/Deployment.yaml
	kubectl apply -f kind/gitserver/Service.yaml
	kubectl rollout restart deployment -n git gitserver

	# Give a little grace period before going to the next steps
	sleep 30


deploy-argocd:
	kustomize build applications/argocd/ | kubectl apply -f -

	@while ! kubectl get secrets \
		-n argocd | grep -q argocd-initial-admin-secret; do \
		echo "Waiting for ArgoCD to start..."; \
		sleep 5; \
	done

	$(MAKE) argo-get-pass

argo-get-pass:
	@printf $(OKGREEN)
	@printf $(BOLD)
	@echo "ArgoCD Login"
	@echo "=========================="
	@echo "ArgoCD Username is: admin"
	@printf "ArgoCD Password is: %s\n" $$(kubectl -n argocd \
		get secret argocd-initial-admin-secret \
		-o jsonpath="{.data.password}" | base64 -d)
	@echo "=========================="
	@printf $(ENDC)


get-etc-hosts:
	@printf $(OKGREEN)
	@printf $(BOLD)
	@echo '# Add this to your hosts'
	@kubectl get svc --all-namespaces -o json | \
		jq -cr '.items[] | select(.status.loadBalancer != {})' | \
		jq -cr '@text "\(.status.loadBalancer.ingress[0].ip)\t<\(.metadata.name)>.example.com"'
	@printf $(ENDC)

deploy-apps: gitserver
	find argocd -name '*.yaml' | xargs -I{} kubectl apply -f {}
	#kustomize build argocd | kubectl apply -f -


deploy: kind gitserver deploy-argocd deploy-metallb
	sleep 30
	@while kubectl get svc --all-namespaces | grep -q '<pending>'; do \
		echo "Waiting for LoadBalancers to get IPs assigned..."; \
		sleep 30; \
	done
	$(MAKE) get-etc-hosts


chromium:
	@printf $(WARNING)
	@printf $(BOLD)
	@echo "Make sure you have closed all your previous chromium windows!"
	@printf $(ENDC)
	$(CHROMIUM) --host-rules="MAP *.aaw.cloud.statcan.ca $$(kubectl get svc -n istio-system istio-ingressgateway -o json | jq -r '.status | .. | .ip? // empty')" &
	#kubectl port-forward -n istio-system svc/istio-ingressgateway 8443:80
