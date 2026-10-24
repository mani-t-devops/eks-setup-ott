SHELL := /bin/bash
.PHONY: up down build grafana prometheus alertmanager app status validate

up:            ## Create everything
	./scripts/up.sh
down:          ## Destroy everything (do this when you stop for the day!)
	./scripts/down.sh
build:         ## Rebuild + push the app image
	./scripts/build-push.sh
grafana:
	kubectl -n monitoring port-forward svc/kps-grafana 3000:80
prometheus:
	kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
alertmanager:
	kubectl -n monitoring port-forward svc/kps-alertmanager 9093:9093
app:
	kubectl -n ott port-forward svc/gateway 8080:8080
status:
	kubectl get nodes -o wide; kubectl -n ott get pods -o wide; kubectl -n monitoring get pods
validate:      ## Offline checks: terraform, YAML, PromQL rules + unit tests
	terraform -chdir=terraform init -backend=false >/dev/null && terraform -chdir=terraform validate
	terraform -chdir=terraform-datadog init -backend=false >/dev/null && terraform -chdir=terraform-datadog validate
	python3 -c "import yaml,glob;[list(yaml.safe_load_all(open(f))) for f in glob.glob('k8s/*.yaml')+glob.glob('monitoring/*.yaml')];print('yaml ok')"
	python3 -c "import yaml;open('monitoring/tests/rules.generated.yaml','w').write(yaml.safe_dump(yaml.safe_load(open('monitoring/prometheus-rules.yaml'))['spec']))"
	promtool check rules monitoring/tests/rules.generated.yaml
	cd monitoring/tests && promtool test rules rules_test.yaml
