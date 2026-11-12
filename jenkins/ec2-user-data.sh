#!/bin/bash
# EC2 user data for the Jenkins server (Amazon Linux 2023, t3.medium).
# Installs Docker, builds the Jenkins image from this repo and starts it on port 8080.
# The instance role gives AWS access (ECR push, EKS describe, SSM, SNS) - no access keys.
set -euxo pipefail
exec > >(tee /var/log/jenkins-setup.log) 2>&1

REPO_URL="https://github.com/rajeshnegd939/StreamingApp.git"
REGION="ap-south-1"

dnf install -y docker git
systemctl enable --now docker

# admin password is kept encrypted in SSM Parameter Store, not in this script
ADMIN_PW=$(aws ssm get-parameter --region "$REGION" --name /streamingapp/jenkins/admin-password \
  --with-decryption --query Parameter.Value --output text)

TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

git clone --depth 1 "$REPO_URL" /opt/streamingapp
docker build -t streamingapp-jenkins /opt/streamingapp/jenkins

docker volume create jenkins_home
docker run -d --name jenkins --restart unless-stopped \
  -p 8080:8080 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c %g /var/run/docker.sock)" \
  -e JENKINS_ADMIN_PASSWORD="$ADMIN_PW" \
  -e GIT_REPO_URL="$REPO_URL" \
  -e JENKINS_URL="http://$PUBLIC_IP:8080/" \
  streamingapp-jenkins

echo "Jenkins is starting on http://$PUBLIC_IP:8080/"
