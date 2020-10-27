SHELL  = /bin/bash
VENV   = .venv
ARCH   = $(shell uname -m)
BUILDX = docker buildx build --push --platform linux/amd64,linux/arm64

include .env
export DOCKER_CLI_EXPERIMENTAL := enabled
export CAMERA_INDEX            := $(CAMERA_INDEX)
export DOCKER_REPO             := $(DOCKER_REPO)
export MQTT_TOPIC              := $(MQTT_TOPIC)
export TF_VAR_region           := $(AWS_REGION)
export TF_VAR_instance_type    := $(AWS_INSTANCE_TYPE)
export TF_VAR_key_name         := $(AWS_SSH_KEY_NAME)
export TF_VAR_bucket_name      := $(AWS_S3_BUCKET_NAME)

$(VENV):
	python3 -mvenv $(VENV) && pip install -r requirements.txt

.PHONY: build-opencv
build-opencv:
	cd opencv && docker build -t $(DOCKER_REPO)/opencv-tensorflow-$(ARCH) .

.PHONY: buildx-opencv
buildx-opencv:
	cd opencv && docker build -t $(DOCKER_REPO)/opencv-tensorflow-$(ARCH) .
	cd opencv && docker buildx build --push --platform linux/arm64 -t $(DOCKER_REPO)/opencv-tensorflow-aarch64 -f Dockerfile.cuda .
	docker push $(DOCKER_REPO)/opencv-tensorflow-$(ARCH)
	docker pull $(DOCKER_REPO)/opencv-tensorflow-aarch64
	docker manifest create --amend imander/opencv-tensorflow imander/opencv-tensorflow-$(ARCH) imander/opencv-tensorflow-aarch64
	docker manifest annotate imander/opencv-tensorflow imander/opencv-tensorflow-aarch64 --arch arm64
	docker manifest push imander/opencv-tensorflow

.PHONY: build-maskdetector
build-maskdetector:
	cd edge/detector && docker build -t $(DOCKER_REPO)/maskdetector-$(ARCH) .

.PHONY: buildx-maskdetector
buildx-maskdetector:
	cd edge/detector && $(BUILDX) -t $(DOCKER_REPO)/maskdetector .

.PHONY: build-processor
build-processor:
	cd cloud/processor && docker build -t $(DOCKER_REPO)/image-processor-$(ARCH) .

.PHONY: buildx-processor
buildx-processor:
	cd cloud/processor && $(BUILDX) -t $(DOCKER_REPO)/image-processor .

.PHONY: build-all
build-all: build-opencv build-maskdetector build-processor

.PHONY: buildx-all
buildx-all: buildx-opencv buildx-maskdetector buildx-processor

.PHONY: push-opencv
push-opencv:
	docker push $(DOCKER_REPO)/opencv-$(ARCH)

.PHONY: push-maskdetector
push-maskdetector:
	docker push $(DOCKER_REPO)/maskdetector-$(ARCH)

.PHONY: push-processor
push-processor:
	docker push $(DOCKER_REPO)/image-processor-$(ARCH)

.PHONY: push-all
push-all: push-opencv push-maskdetector push-processor

.PHONY: plan
plan:
	cd infrastructure/terraform && terraform plan

.PHONY: cloud-up
cloud-up:
	cd infrastructure/terraform && terraform apply -auto-approve

.PHONY: cloud-down
cloud-down:
	cd infrastructure/terraform && \
		terraform destroy -auto-approve --target=aws_instance.w251_image_server

.PHONY: cloud-down
cloud-down-all:
	cd infrastructure/terraform && terraform destroy -auto-approve

.PHONY: ansible-inventory
ansible-inventory:
	sed -e "s/IMAGE_SERVER/$$(jq -r '.outputs.image_server_public_ip.value' < infrastructure/terraform/terraform.tfstate)/" \
		-e "s/EDGE_SERVER/$(EDGE_SERVER)/" \
		-e "s/EDGE_USER/$(EDGE_USER)/" \
		infrastructure/ansible/inventory.tmpl > infrastructure/ansible/inventory

.PHONY: config-up
config-up: $(VENV) ansible-inventory
	source $(VENV)/bin/activate && \
	cd infrastructure/ansible && \
	ansible-playbook deploy.yml --tags "start" -i inventory --ask-become-pass
	@echo -e "\n\nCaptured images can be viewed at the following URL:"
	@echo -e "http://$(AWS_S3_BUCKET_NAME).s3-website-$(AWS_REGION).amazonaws.com"

.PHONY: config-down
config-down: ansible-inventory
	source $(VENV)/bin/activate && \
	cd infrastructure/ansible && \
	ansible-playbook deploy.yml --tags "stop" -i inventory --ask-become-pass

.PHONY: deploy
deploy: cloud-up config-up

.PHONY: destroy
destroy: config-down cloud-down

.PHONY: destroy-all
destroy-all: config-down cloud-down-all
